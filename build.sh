#!/usr/bin/env bash
# Copyright [2016] [Kevin Carter]
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Load all functions
source functions.sh

# If you were running ssh-agent with forwarding this will clear out the keys
#  in your cache which can cause confusion.
killall ssh-agent; eval `ssh-agent`

if [ ! -f "/root/.ssh/id_rsa" ];then
  ssh-keygen -t rsa -N ''
fi

cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

apt-get update && apt-get install -y qemu-kvm libvirt-bin virtinst bridge-utils virt-manager lvm2

virsh net-autostart default --disable
virsh net-destroy default

if ! grep "^source.*cfg$" /etc/network/interfaces; then
  echo 'source /etc/network/interfaces.d/*.cfg' | tee -a /etc/network/interfaces
fi

# create kvm bridges
cp templates/kvm-bridges.cfg /etc/network/interfaces.d/kvm-bridges.cfg
for i in br-dhcp br-mgmt br-vlan br-storage br-vxlan; do
  ifup $i;
done

# Set the forward rule
sysctl -w net.ipv4.ip_forward=1 | tee -a /etc/sysctl.conf

# Add rules from the INPUT chain
iptables -w -I INPUT -i "br-dhcp" -p udp --dport 67 -j ACCEPT
iptables -w -I INPUT -i "br-dhcp" -p tcp --dport 67 -j ACCEPT
iptables -w -I INPUT -i "br-dhcp" -p udp --dport 53 -j ACCEPT
iptables -w -I INPUT -i "br-dhcp" -p tcp --dport 53 -j ACCEPT

# Add rules from the FORWARDING chain
iptables -w -I FORWARD -i "br-dhcp" -j ACCEPT
iptables -w -I FORWARD -o "br-dhcp" -j ACCEPT

# Add rules from the nat POSTROUTING chain
iptables -w -t nat \
            -A POSTROUTING \
            -s "10.0.0.0/24" ! \
            -d "10.0.0.0/24" \
            -j MASQUERADE

# Add rules from the mangle POSTROUTING chain
iptables -w -t mangle \
            -A POSTROUTING \
            -s "10.0.0.0/24" \
            -o "br-dhcp" \
            -p udp \
            -m udp \
            --dport 68 \
            -j CHECKSUM \
            --checksum-fill

# Enable partitioning of the "${DATA_DISK_DEVICE}"
PARTITION_HOST=${PARTITION_HOST:-true}
if [[ "${PARTITION_HOST}" = true ]]; then
  # Set the data disk device, if unset the largest unpartitioned device will be used to for host VMs
  DATA_DISK_DEVICE="${DATA_DISK_DEVICE:-$(lsblk -brndo NAME,TYPE,FSTYPE,RO,SIZE | awk '/d[b-z]+ disk +0/{ if ($4>m){m=$4; d=$1}}; END{print d}')}"
  parted --script /dev/${DATA_DISK_DEVICE} mklabel gpt
  parted --align optimal --script /dev/${DATA_DISK_DEVICE} mkpart kvm ext4 0% 100%
  mkfs.ext4 /dev/${DATA_DISK_DEVICE}1
  if ! grep -qw "^/dev/${DATA_DISK_DEVICE}1" /etc/fstab; then
    echo "/dev/${DATA_DISK_DEVICE}1 ${BOOTSTRAP_AIO_DIR} ext4 defaults 0 0" >> /etc/fstab
  fi
  mount -a
fi

# Install cobbler
wget -qO - http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/Release.key | apt-key add -
add-apt-repository "deb http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/ ./"
apt-get update && apt-get -y install cobbler dhcp3-server debmirror isc-dhcp-server ipcalc tftpd tftp fence-agents iptables-persistent

# Move Cobbler Apache config to the right place
cp /etc/apache2/conf.d/cobbler.conf /etc/apache2/conf-available/
cp /etc/apache2/conf.d/cobbler_web.conf /etc/apache2/conf-available/

# Enable the above config
a2enconf cobbler cobbler_web

# Enable Proxy modules
a2enmod proxy
a2enmod proxy_http

# Basic cobbler setup
sed -i 's/^manage_dhcp\:.*/manage_dhcp\: 1/g' /etc/cobbler/settings
sed -i 's/^restart_dhcp\:.*/restart_dhcp\: 1/g' /etc/cobbler/settings
sed -i 's/^next_server\:.*/next_server\: 10.0.0.200/g' /etc/cobbler/settings
sed -i 's/^server\:.*/server\: 10.0.0.200/g' /etc/cobbler/settings
sed -i 's/^http_port\:.*/http_port\: 5150/g' /etc/cobbler/settings
sed -i 's/^INTERFACES.*/INTERFACES="br-dhcp"/g' /etc/default/isc-dhcp-server

# Fix Apache conf to match 2.4 configuration
sed -i "/Order allow,deny/d" /etc/apache2/conf-enabled/cobbler*.conf
sed -i "s/Allow from all/Require all granted/g" /etc/apache2/conf-enabled/cobbler*.conf
sed -i "s/^Listen 80/Listen 5150/g" /etc/apache2/ports.conf
sed -i "s/\:80/\:5150/g" /etc/apache2/sites-available/000-default.conf

# Fix TFTP server arguments in cobbler template to enable it to work on Ubuntu
sed -i "s/server_args .*/server_args             = -s \$args/" /etc/cobbler/tftpd.template

# Permission Workarounds
mkdir -p /tftpboot
chown www-data /var/lib/cobbler/webui_sessions

#  when templated replace \$ with $
cp templates/dhcp.template /etc/cobbler/dhcp.template

# Create a trusty sources file
cp templates/trusty-sources.list /var/www/html/trusty-sources.list

# Set the default preseed device name.
#  This is being set because sda is on hosts, vda is kvm, xvda is xen.
DEVICE_NAME="${DEVICE_NAME:-vda}"
# This gets the root users SSH-public-key
SSHKEY=$(cat /root/.ssh/id_rsa.pub)
# This is set to instruct the preseed what the default network is expected to be
DEFAULT_NETWORK="${DEFAULT_NETWORK:-eth0}"

# Template the seed files
for seed_file in templates/pre-seeds/*.seed; do
  cp "${seed_file}" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s/__DEVICE_NAME__/${DEVICE_NAME}/g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s|__SSHKEY__|${SSHKEY}|g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s/__DEFAULT_NETWORK__/${DEFAULT_NETWORK}/g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
done

# Restart services again and configure autostart
service cobblerd restart
service apache2 restart
service xinetd stop
service xinetd start
update-rc.d cobblerd defaults

# Get ubuntu server image
mkdir -p /var/cache/iso
pushd /var/cache/iso
  wget http://releases.ubuntu.com/trusty/ubuntu-14.04.4-server-amd64.iso
popd

# import cobbler image
if ! cobbler distro list | grep -qw "ubuntu-14.04.4-server-x86_64"; then
  mkdir -p /mnt/iso
  mount -o loop /var/cache/iso/ubuntu-14.04.4-server-amd64.iso /mnt/iso
  cobbler import --name=ubuntu-14.04.4-server-amd64 --path=/mnt/iso
  umount /mnt/iso
fi

# Create cobbler profile
for seed_file in /var/lib/cobbler/kickstarts/ubuntu*14.04*.seed; do
  if ! cobbler profile list | grep -qw "${seed_file#*'/'}"; then
    cobbler profile add \
      --name "${seed_file#*'/'}" \
      --distro ubuntu-14.04.4-server-x86_64 \
      --kickstart "${seed_file}"
  fi
done

# sync cobbler
cobbler sync

# Get Loaders
cobbler get-loaders

# Update Cobbler Signatures
cobbler signature update

# Create cobbler systems
for node_type in $(get_all_types); do
  for node in $(get_host_type ${node_type}); do
    if ! cobbler system list | grep -qw "${node%%":"*}"; then
      cobbler system add \
        --name="${node%%':'*}" \
        --profile="ubuntu-server-14.04-unattended-cobbler-${node_type}.seed" \
        --hostname=${node%%":"*}.openstackci.local \
        --kopts="interface=${DEFAULT_NETWORK}" \
        --interface=${DEFAULT_NETWORK} \
        --mac="52:54:00:bd:81:${node:(-2)}" \
        --ip-address="10.0.0.${node#*":"}" \
        --subnet=255.255.255.0 \
        --gateway=10.0.0.200 \
        --name-servers=8.8.8.8 8.8.4.4 \
        --static=1
    fi
  done
done

# sync cobbler
cobbler sync

# Restart XinetD
service xinetd stop
service xinetd start

# Create the libvirt networks used for the Host VMs
for network in br-dhcp br-mgmt br-vxlan br-storage br-vlan; do
  if ! virsh net-list |  grep -qw "${network}"; then
    sed "s/__NETWORK__/${network}/g" templates/libvirt-network.xml > /etc/libvirt/qemu/networks/${network}.xml
    virsh net-define --file /etc/libvirt/qemu/networks/${network}.xml
    virsh net-create --file /etc/libvirt/qemu/networks/${network}.xml
    virsh net-autostart ${network}
  fi
done

# Create the VM root disk then define and start the VMs.
for node in $(get_all_hosts); do
  cp templates/vmnode.openstackci.local.xml /etc/libvirt/qemu/${node%%":"*}.openstackci.local.xml
  sed -i "s/__NODE__/${node%%":"*}/g" /etc/libvirt/qemu/${node%%":"*}.openstackci.local.xml
  sed -i "s/__COUNT__/${node:(-2)}/g" /etc/libvirt/qemu/${node%%":"*}.openstackci.local.xml
  cp templates/vmnode.openstackci.local-bridges.cfg /opt/osa-${node%%":"*}.openstackci.local-bridges.cfg
  sed -i "s/__COUNT__/${node#*":"}/g" /opt/osa-${node%%":"*}.openstackci.local-bridges.cfg
done

# Kick all of the VMs to run the cloud
#  !!!THIS TASK WILL DESTROY ALL OF THE ROOT DISKS IF THEY ALREADY EXIST!!!
rekick_vms

# Wait here for all nodes to be booted and ready with SSH
wait_ssh

# Do the basic host setup for all nodes
for node in $(get_all_hosts); do
scp -o StrictHostKeyChecking=no /opt/osa-${node%%":"*}.openstackci.local-bridges.cfg 10.0.0.${node#*":"}:/etc/network/interfaces.d/osa-${node%%":"*}.openstackci.local-bridges.cfg
ssh -q -o StrictHostKeyChecking=no 10.0.0.${node#*":"} <<EOF
apt-get clean && apt-get update
if ! grep "^source.*cfg$" /etc/network/interfaces; then
  echo 'source /etc/network/interfaces.d/*.cfg' | tee -a /etc/network/interfaces
fi
shutdown -r now
EOF
done

# Wait here for all nodes to be booted and ready with SSH
wait_ssh

# Instruct the system to deploy OpenStack Ansible
DEPLOY_OSA=${DEPLOY_OSA:-true}
[[ "${DEPLOY_OSA}" = true ]] && source osa-deploy.sh

#!/usr/bin/env bash
set -eu
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
if [ ! -f "/root/.functions.rc" ];then
  # Make the rekick function part of the main general shell
  declare -f rekick_vms | tee /root/.functions.rc
  if ! grep -q 'source /root/.functions.rc' /root/.bashrc; then
    echo 'source /root/.functions.rc' | tee -a /root/.bashrc
  fi
fi

# If you were running ssh-agent with forwarding this will clear out the keys
#  in your cache which can cause confusion.
killall ssh-agent; eval `ssh-agent`

if [ ! -f "/root/.ssh/id_rsa" ];then
  ssh-keygen -t rsa -N ''
fi

# This gets the root users SSH-public-key
SSHKEY=$(cat /root/.ssh/id_rsa.pub)
if ! grep -q "${SSHKEY}" /root/.ssh/authorized_keys; then
  cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
fi

apt-get update && apt-get install -y qemu-kvm libvirt-bin virtinst bridge-utils virt-manager lvm2

if ! grep "^source.*cfg$" /etc/network/interfaces; then
  echo 'source /etc/network/interfaces.d/*.cfg' | tee -a /etc/network/interfaces
fi

# create kvm bridges
cp -v templates/kvm-bridges.cfg /etc/network/interfaces.d/kvm-bridges.cfg
for i in br-dhcp br-mgmt br-vlan br-storage br-vxlan; do
  ifup $i;
done

# Set the forward rule
if ! grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf; then
  sysctl -w net.ipv4.ip_forward=1 | tee -a /etc/sysctl.conf
fi

# Add rules from the INPUT chain
iptables_general_rule_add 'INPUT -i br-dhcp -p udp --dport 67 -j ACCEPT'
iptables_general_rule_add 'INPUT -i br-dhcp -p tcp --dport 67 -j ACCEPT'
iptables_general_rule_add 'INPUT -i br-dhcp -p udp --dport 53 -j ACCEPT'
iptables_general_rule_add 'INPUT -i br-dhcp -p tcp --dport 53 -j ACCEPT'

# Add rules from the FORWARDING chain
iptables_general_rule_add 'FORWARD -i br-dhcp -j ACCEPT'
iptables_general_rule_add 'FORWARD -o br-dhcp -j ACCEPT'

# Add rules from the nat POSTROUTING chain
iptables_filter_rule_add nat 'POSTROUTING -s 10.0.0.0/24 ! -d 10.0.0.0/24 -j MASQUERADE'

# Add rules from the mangle POSTROUTING chain
iptables_filter_rule_add mangle 'POSTROUTING -s 10.0.0.0/24 -o br-dhcp -p udp -m udp --dport 68 -j CHECKSUM --checksum-fill'

# Enable partitioning of the "${DATA_DISK_DEVICE}"
PARTITION_HOST=${PARTITION_HOST:-true}
if [[ "${PARTITION_HOST}" = true ]]; then
  # Set the data disk device, if unset the largest unpartitioned device will be used to for host VMs
  DATA_DISK_DEVICE="${DATA_DISK_DEVICE:-$(lsblk -brndo NAME,TYPE,FSTYPE,RO,SIZE | awk '/d[b-z]+ disk +0/{ if ($4>m){m=$4; d=$1}}; END{print d}')}"
  parted --script /dev/${DATA_DISK_DEVICE} mklabel gpt
  parted --align optimal --script /dev/${DATA_DISK_DEVICE} mkpart kvm ext4 0% 100%
  mkfs.ext4 /dev/${DATA_DISK_DEVICE}1
  if ! grep -qw "^/dev/${DATA_DISK_DEVICE}1" /etc/fstab; then
    echo "/dev/${DATA_DISK_DEVICE}1 /var/lib/libvirt/images/ ext4 defaults 0 0" >> /etc/fstab
  fi
  mount -a
fi

# Install cobbler
wget -qO - http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/Release.key | apt-key add -
add-apt-repository "deb http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/ ./"
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install cobbler dhcp3-server debmirror isc-dhcp-server ipcalc tftpd tftp fence-agents iptables-persistent

# Basic cobbler setup
sed -i 's/^manage_dhcp\:.*/manage_dhcp\: 1/g' /etc/cobbler/settings
sed -i 's/^restart_dhcp\:.*/restart_dhcp\: 1/g' /etc/cobbler/settings
sed -i 's/^next_server\:.*/next_server\: 10.0.0.200/g' /etc/cobbler/settings
sed -i 's/^server\:.*/server\: 10.0.0.200/g' /etc/cobbler/settings
sed -i 's/^http_port\:.*/http_port\: 5150/g' /etc/cobbler/settings
sed -i 's/^INTERFACES.*/INTERFACES="br-dhcp"/g' /etc/default/isc-dhcp-server

# Move Cobbler Apache config to the right place
cp -v /etc/apache2/conf.d/cobbler.conf /etc/apache2/conf-available/
cp -v /etc/apache2/conf.d/cobbler_web.conf /etc/apache2/conf-available/

# Fix Apache conf to match 2.4 configuration
sed -i "/Order allow,deny/d" /etc/apache2/conf-available/cobbler*.conf
sed -i "s/Allow from all/Require all granted/g" /etc/apache2/conf-available/cobbler*.conf
sed -i "s/^Listen 80/Listen 5150/g" /etc/apache2/ports.conf
sed -i "s/\:80/\:5150/g" /etc/apache2/sites-available/000-default.conf

# Enable the above config
a2enconf cobbler cobbler_web

# Enable Proxy modules
a2enmod proxy
a2enmod proxy_http

# Fix TFTP server arguments in cobbler template to enable it to work on Ubuntu
sed -i "s/server_args .*/server_args             = -s \$args/" /etc/cobbler/tftpd.template

# Permission Workarounds
mkdir -p /tftpboot
chown www-data /var/lib/cobbler/webui_sessions

#  when templated replace \$ with $
cp -v templates/dhcp.template /etc/cobbler/dhcp.template

# Create a trusty sources file
cp -v templates/trusty-sources.list /var/www/html/trusty-sources.list

# Set the default preseed device name.
#  This is being set because sda is on hosts, vda is kvm, xvda is xen.
DEVICE_NAME="${DEVICE_NAME:-vda}"

# This is set to instruct the preseed what the default network is expected to be
DEFAULT_NETWORK="${DEFAULT_NETWORK:-eth0}"

# Template the seed files
for seed_file in $(ls -1 templates/pre-seeds); do
  cp -v "templates/pre-seeds/${seed_file}" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s|__DEVICE_NAME__|${DEVICE_NAME}|g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s|__SSHKEY__|${SSHKEY}|g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
  sed -i "s|__DEFAULT_NETWORK__|${DEFAULT_NETWORK}|g" "/var/lib/cobbler/kickstarts/${seed_file#*'/'}"
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
  if [ -f "/var/cache/iso/ubuntu-14.04.4-server-amd64.iso" ]; then
    rm /var/cache/iso/ubuntu-14.04.4-server-amd64.iso
  fi
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
  if ! cobbler profile list | grep -qw "${seed_file##*'/'}"; then
    cobbler profile add \
      --name "${seed_file##*'/'}" \
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
    if cobbler system list | grep -qw "${node%%':'*}"; then
      echo "removing node ${node%%':'*} from the cobbler system"
      cobbler system remove --name "${node%%':'*}"
    fi
    echo "adding node ${node%%':'*} from the cobbler system"
    cobbler system add \
      --name="${node%%':'*}" \
      --profile="ubuntu-server-14.04-unattended-cobbler-${node_type}.seed" \
      --hostname="${node%%":"*}.openstackci.local" \
      --kopts="interface=${DEFAULT_NETWORK}" \
      --interface="${DEFAULT_NETWORK}" \
      --mac="52:54:00:bd:81:${node:(-2)}" \
      --ip-address="10.0.0.${node#*":"}" \
      --subnet=255.255.255.0 \
      --gateway=10.0.0.200 \
      --name-servers=8.8.8.8 8.8.4.4 \
      --static=1
  done
done

# Restart XinetD
service xinetd stop
service xinetd start

# Remove the default libvirt networks
if virsh net-list |  grep -qw "default"; then
  virsh net-autostart default --disable
  virsh net-destroy default
fi

# Create the libvirt networks used for the Host VMs
for network in br-dhcp br-mgmt br-vxlan br-storage br-vlan; do
  if ! virsh net-list |  grep -qw "${network}"; then
    sed "s/__NETWORK__/${network}/g" templates/libvirt-network.xml > /etc/libvirt/qemu/networks/${network}.xml
    virsh net-define --file /etc/libvirt/qemu/networks/${network}.xml
    virsh net-create --file /etc/libvirt/qemu/networks/${network}.xml
    virsh net-autostart ${network}
  fi
done

# Instruct the system to Kick all of the VMs
KICK_VMS=${KICK_VMS:-true}
[[ "${KICK_VMS}" = true ]] && source kick-vms.sh

# Instruct the system to deploy OpenStack Ansible
DEPLOY_OSA=${DEPLOY_OSA:-true}
[[ "${DEPLOY_OSA}" = true ]] && source osa-deploy.sh

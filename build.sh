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

# If you were running ssh-agent with forwarding this will clear out the keys
#  in your cache which can cause confusion.
killall ssh-agent; eval `ssh-agent`

if [ ! -f "/root/.ssh/id_rsa" ];then
  ssh-keygen -t rsa -N ''
fi

cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

apt-get update && apt-get install -y qemu-kvm libvirt-bin virtinst bridge-utils virt-manager

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

# Create kvm storage pool
parted --script /dev/sdb mklabel gpt
parted --script /dev/sdb mkpart kvm ext4 0% 100%
mkfs.ext4 /dev/sdb1
echo "$(blkid | awk '/\/dev\/sdb1/ {print $2}') /var/lib/libvirt/images ext4 errors=remount-ro 0 1" | tee -a /etc/fstab
mount -a

# Install cobbler
wget -qO - http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/Release.key | apt-key add -
add-apt-repository "deb http://download.opensuse.org/repositories/home:/libertas-ict:/cobbler26/xUbuntu_14.04/ ./"
apt-get update && apt-get -y install cobbler dhcp3-server debmirror isc-dhcp-server ipcalc tftpd tftp fence-agents

# Move Cobbler Apache config to the right place
cp /etc/apache2/conf.d/cobbler.conf /etc/apache2/conf-available/
cp /etc/apache2/conf.d/cobbler_web.conf /etc/apache2/conf-available/

# Fix Apache conf to match 2.4 configuration
sed -i "/Order allow,deny/d" /etc/apache2/conf-enabled/cobbler*.conf
sed -i "s/Allow from all/Require all granted/" /etc/apache2/conf-enabled/cobbler*.conf
sed -i "s/^Listen 80/Listen 5150/" /etc/apache2/ports.conf
sed -i "s/\:80/\:5150/" /etc/apache2/sites-available/000-default.conf

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

# Fix TFTP server arguments in cobbler template to enable it to work on Ubuntu
sed -i "s/server_args .*/server_args             = -s \$args/" /etc/cobbler/tftpd.template

# Permission Workarounds
mkdir -p /tftpboot
chown www-data /var/lib/cobbler/webui_sessions

#  when templated replace \$ with $
cp templates/dhcp.template /etc/cobbler/dhcp.template

# Create a trusty sources file
cp templates/trusty-sources.list /var/www/html/trusty-sources.list

# This is being set because sda is on hosts, vda is kvm, xvda is xen.
DEVICE_NAME="vda"
# This gets the root users SSH-public-key
SSHKEY=$(cat /root/.ssh/id_rsa.pub)
# This is set to instruct the preseed what the default network is expected to be
DEFAULT_NETWORK="eth0"

#  when templated replace \$ with $ and \\ with \
cp templates/ubuntu-server-14.04-unattended-cobbler.seed /var/lib/cobbler/kickstarts/ubuntu-server-14.04-unattended-cobbler.seed
sed -i "s/__DEVICE_NAME__/${DEVICE_NAME}/g" /var/lib/cobbler/kickstarts/ubuntu-server-14.04-unattended-cobbler.seed
sed -i "s/__SSHKEY__/${SSHKEY}/g" /var/lib/cobbler/kickstarts/ubuntu-server-14.04-unattended-cobbler.seed
sed -i "s/__DEFAULT_NETWORK__/${DEFAULT_NETWORK}/g" /var/lib/cobbler/kickstarts/ubuntu-server-14.04-unattended-cobbler.seed

# Restart services again and configure autostart
service cobblerd restart
service apache2 restart
service xinetd restart
update-rc.d cobblerd defaults

# Get ubuntu server image
mkdir -p /var/cache/iso
pushd /var/cache/iso
  wget http://releases.ubuntu.com/trusty/ubuntu-14.04.4-server-amd64.iso
popd

# import cobbler image
mkdir -p /mnt/iso
mount -o loop /var/cache/iso/ubuntu-14.04.4-server-amd64.iso /mnt/iso
cobbler import --name=ubuntu-14.04.4-server-amd64 --path=/mnt/iso
umount /mnt/iso

cobbler profile add \
  --name ubuntu-14.04.4-server-unattended \
  --distro ubuntu-14.04.4-server-x86_64 \
  --kickstart /var/lib/cobbler/kickstarts/ubuntu-server-14.04-unattended-cobbler.seed

# sync cobbler
cobbler sync

# Get Loaders
cobbler get-loaders

# Update Cobbler Signatures
cobbler signature update

# Create the cobbler system
count=0
for node in infra1 infra2 infra3 logging1 compute1 compute2 swift1 swift2 storage1; do
  node_count="$((count++))"
  cobbler system add \
    --name=${node} \
    --profile=ubuntu-14.04.4-server-unattended \
    --hostname=${node}.openstackci.local \
    --kopts="interface=${DEFAULT_NETWORK}" \
    --interface=${DEFAULT_NETWORK} \
    --mac="52:54:00:bd:81:d${node_count}" \
    --ip-address="10.0.0.10${node_count}" \
    --subnet=255.255.255.0 \
    --gateway=10.0.0.200 \
    --name-servers=8.8.8.8 8.8.4.4 \
    --static=1
done

# Create the libvirt networks used for the Host VMs
for network in br-dhcp br-mgmt br-vxlan br-storage br-vlan; do
  sed "s/__NETWORK__/${network}/g" templates/libvirt-network.xml > /etc/libvirt/qemu/networks/${network}.xml
  virsh net-define --file /etc/libvirt/qemu/networks/${network}.xml
  virsh net-create --file /etc/libvirt/qemu/networks/${network}.xml
  virsh net-autostart ${network}
done

count=0
for node in infra1 infra2 infra3 logging1 compute1 compute2 swift1 swift2 storage1; do
  node_count="$((count++))"
  qemu-img create -f qcow2 /var/lib/libvirt/images/${node}.openstackci.local.img 252G
  cp templates/vmnode.openstackci.local.xml /etc/libvirt/qemu/${node}.openstackci.local.xml
  sed -i "s/__NODE__/${node}/g" /etc/libvirt/qemu/${node}.openstackci.local.xml
  sed -i "s/__COUNT__/${count}/g" /etc/libvirt/qemu/${node}.openstackci.local.xml
  virsh define /etc/libvirt/qemu/${node}.openstackci.local.xml
  virsh create /etc/libvirt/qemu/${node}.openstackci.local.xml
  cp templates/vmnode.openstackci.local-bridges.cfg /opt/osa-${node}.openstackci.local-bridges.cfg
  sed -i "s/__COUNT__/${count}/g" /opt/osa-${node}.openstackci.local-bridges.cfg
done

function wait_ssh() {
count=0
echo "Waiting for all nodes to become available. This can take around 10 min"
for node in infra1 infra2 infra3 logging1 compute1 compute2 swift1 swift2 storage1; do
node_count="$((count++))"
    echo "Waiting for node: ${node}"
    ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 10.0.0.10${node_count} exit > /dev/null
    while test $? -gt 0; do
      sleep 15
      ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 10.0.0.10${node_count} exit > /dev/null
    done
done
}

wait_ssh

count=0
for node in infra1 infra2 infra3 logging1 compute1 compute2 swift1 swift2 storage1; do
node_count="$((count++))"
echo "Setup node bridge configs: ${node}"
scp -o StrictHostKeyChecking=no /opt/osa-${node}.openstackci.local-bridges.cfg 10.0.0.10${node_count}:/etc/network/interfaces.d/osa-${node}.openstackci.local-bridges.cfg
ssh -q -o StrictHostKeyChecking=no 10.0.0.10${node_count} <<EOF
if ! grep "^source.*cfg$" /etc/network/interfaces; then
echo 'source /etc/network/interfaces.d/*.cfg' | tee -a /etc/network/interfaces
fi
umount /deleteme || true
echo y | lvremove  /dev/lxc/deleteme00 || true
sed -i 's/^\/dev\/mapper\/lxc-deleteme00.*//g' /etc/fstab
for i in br-dhcp br-mgmt br-vlan br-storage br-vxlan; do
  ifup $i;
done
EOF
done

# Infra storage setup
for node in 10.0.0.100 10.0.0.101 10.0.0.102; do
ssh -q -o StrictHostKeyChecking=no ${node} <<EOF
umount /var/lib/nova
echo y | lvremove  /dev/lxc/nova00 || true
sed -i 's/^\/dev\/mapper\/lxc-nova00.*//g' /etc/fstab
lvresize -r -l+100%FREE /dev/lxc/root00
EOF
done

# Logging storage setup
for node in 10.0.0.103; do
ssh -q -o StrictHostKeyChecking=no ${node} <<EOF
umount /var/lib/nova
echo y | lvremove  /dev/lxc/nova00 || true
sed -i 's/^\/dev\/mapper\/lxc-nova00.*//g' /etc/fstab
lvresize -r -l+100%FREE /dev/lxc/openstack00
EOF
done

# swift storage setup
for node in 10.0.0.106 10.0.0.107; do
ssh -q -o StrictHostKeyChecking=no ${node} <<EOF
umount /var/lib/nova
echo y | lvremove  /dev/lxc/nova00 || true
sed -i 's/^\/dev\/mapper\/lxc-nova00.*//g' /etc/fstab
# apt-get update && apt-get -y install xfsprogs
for disk in disk1 disk2 disk3; do
lvcreate --name \${disk} -L 30G lxc
mkfs.xfs /dev/lxc/\${disk}
mkdir -p /src/\${disk}
mount /dev/lxc/\${disk} /srv/\${disk}
echo "/dev/mapper/lxc-\${disk} /srv/\${disk} xfs defaults 0 0" | tee -a /etc/fstab
done

EOF
done

# Storage storage setup
for node in 10.0.0.108; do
ssh -q -o StrictHostKeyChecking=no ${node} <<EOF
umount /var/lib/nova
echo y | lvremove  /dev/lxc/nova00 || true
sed -i 's/^\/dev\/mapper\/lxc-nova00.*//g' /etc/fstab
lvcreate --name cinder -l 100%FREE lxc
vgcreate cinder-volumes /dev/lxc/cinder
EOF
done

# Deploy OpenStack-Ansible source code
apt-get install -y git tmux
pushd /opt
  git clone https://github.com/openstack/openstack-ansible
  cp -R openstack-ansible/etc/openstack_deploy /etc/openstack_deploy
popd

# Create the swift config
cp templates/osa-swift.yml /etc/openstack_deploy/conf.d/swift.yml

# Create the OpenStack User Config
HOSTIP="$(ip route get 1 | awk '{print $NF;exit}')"
sed "s/__HOSTIP__/${HOSTIP}/g" templates/openstack_user_config.yml > /etc/openstack_deploy/openstack_user_config.yml

pushd /opt/openstack-ansible/
  bash ./scripts/bootstrap-ansible.sh
  python ./scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml
  # This is happening so the VMs running the infra use less storage
  echo 'lxc_container_backing_store: dir' | tee -a /etc/openstack_deploy/user_variables.yml
  # Tempest is being configured to use a known network
  echo 'tempest_public_subnet_cidr: 172.29.248.0/22' | tee -a /etc/openstack_deploy/user_variables.yml
  # This makes running neutron in a distributed system easier and a lot less noisy
  echo 'neutron_l2_population: True' | tee -a /etc/openstack_deploy/user_variables.yml
popd

pushd /opt/openstack-ansible/playbooks
# Running the HAP play is done because it "may" be needed. Note: In Master its not.
openstack-ansible haproxy-install.yml

# Setup everything else
openstack-ansible setup-everything.yml

# This is optional and only being done to give the cloud networks and an image.
#  The tempest install will work out of the box because the deployment is setup
#  already with all of the correct networks, devices, and other bits. If you want
#  to test with tempest the OSA script will work out the box. Post deployment you
#  can test with the following: `cd /opt/openstack-ansible; ./scripts/run-tempest.sh`
openstack-ansible os-tempest-install.yml
popd

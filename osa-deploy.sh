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

# Deploy OpenStack-Ansible source code
apt-get install -y git tmux
pushd /opt
  git clone https://github.com/openstack/openstack-ansible || true
  cp -vR openstack-ansible/etc/openstack_deploy /etc/openstack_deploy
popd

# Create the OpenStack User Config
HOSTIP="$(ip route get 1 | awk '{print $NF;exit}')"
sed "s/__HOSTIP__/${HOSTIP}/g" templates/openstack_user_config.yml > /etc/openstack_deploy/openstack_user_config.yml

# Create the swift config: function group_name host_type
cp -v templates/osa-swift.yml /etc/openstack_deploy/conf.d/swift.yml


### =========== WRITE OF conf.d FILES =========== ###
# Setup cinder hosts: function group_name host_type
write_osa_cinder_confd storage_hosts cinder

# Setup nova hosts: function group_name host_type
write_osa_general_confd compute_hosts nova_compute

# Setup infra hosts: function group_name host_type
write_osa_general_confd identity_hosts infra
write_osa_general_confd repo-infra_hosts infra
write_osa_general_confd storage-infra_hosts infra
write_osa_general_confd os-infra_hosts infra
write_osa_general_confd shared-infra_hosts infra

# Setup logging hosts: function group_name host_type
write_osa_general_confd log_hosts logging

# Setup network hosts: function group_name host_type
write_osa_general_confd network_hosts network

# Setup swift proxy hosts: function group_name host_type
write_osa_swift_proxy_confd swift-proxy_hosts swift

# Setup swift storage hosts: function group_name host_type
write_osa_swift_storage_confd swift_hosts swift
### =========== END WRITE OF conf.d FILES =========== ###


# Set the OSA branch for this script to deploy
OSA_BRANCH=${OSA_BRANCH:-master}
pushd /opt/openstack-ansible/
  git checkout ${OSA_BRANCH}
  bash ./scripts/bootstrap-ansible.sh
  python ./scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml
  # This is happening so the VMs running the infra use less storage
  if ! grep -q "^lxc_container_backing_store" /etc/openstack_deploy/user_variables.yml; then
    echo 'lxc_container_backing_store: dir' | tee -a /etc/openstack_deploy/user_variables.yml
  fi
  # Tempest is being configured to use a known network
  if ! grep -q "^tempest_public_subnet_cidr" /etc/openstack_deploy/user_variables.yml; then
    echo 'tempest_public_subnet_cidr: 172.29.248.0/22' | tee -a /etc/openstack_deploy/user_variables.yml
  fi
  # This makes running neutron in a distributed system easier and a lot less noisy
  if ! grep -q "^neutron_l2_population" /etc/openstack_deploy/user_variables.yml; then
    echo 'neutron_l2_population: True' | tee -a /etc/openstack_deploy/user_variables.yml
  fi
  # This makes the glance image store use swift instead of the file backend
  if ! grep -q "^glance_default_store" /etc/openstack_deploy/user_variables.yml; then
    echo 'glance_default_store: swift' | tee -a /etc/openstack_deploy/user_variables.yml
  fi
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

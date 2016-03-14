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

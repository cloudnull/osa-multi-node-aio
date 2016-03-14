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

function get_host_type () {
python <<EOL
import json
with open('hosts.json') as f:
    x = json.loads(f.read())
for k, v in x.get("$1").items():
    print('%s:%s' % (k, v))
EOL
}

function get_all_hosts () {
python <<EOL
import json
with open('hosts.json') as f:
    x = json.loads(f.read())
for i in x.values():
    for k, v in i.items():
      print('%s:%s' % (k, v))
EOL
}

function get_all_types () {
python <<EOL
import json
with open('hosts.json') as f:
    x = json.loads(f.read())
for i in x.keys():
    print(i)
EOL
}

function wait_ssh() {
echo "Waiting for all nodes to become available. This can take around 10 min"
for node in $(get_all_hosts); do
    echo "Waiting for node: ${node%%":"*} on 10.0.0.${node#*":"}"
    ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 10.0.0.${node#*":"} exit > /dev/null
    while test $? -gt 0; do
      sleep 15
      ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 10.0.0.${node#*":"} exit > /dev/null
    done
done
}

function rekick_vms() {
for node in $(get_all_hosts); do
  for node_uuid in $(virsh list --all --uuid); do
    virsh destroy "${node_uuid}"
  done
  qemu-img create -f qcow2 /var/lib/libvirt/images/${node%%":"*}.openstackci.local.img 252G
  virsh define /etc/libvirt/qemu/${node%%":"*}.openstackci.local.xml || true
  virsh create /etc/libvirt/qemu/${node%%":"*}.openstackci.local.xml || true
done
}
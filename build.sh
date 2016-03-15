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

# Instruct the system do all of the require host setup
HOST_SETUP=${HOST_SETUP:-true}
[[ "${HOST_SETUP}" = true ]] && source host-setup.sh

# Instruct the system do all of the cobbler setup
COBBLER_SETUP=${COBBLER_SETUP:-true}
[[ "${COBBLER_SETUP}" = true ]] && source cobbler-setup.sh

# Instruct the system do all of the cobbler setup
VIRSH_NET_SETUP=${VIRSH_NET_SETUP:-true}
[[ "${VIRSH_NET_SETUP}" = true ]] && source virsh-net-setup.sh

# Instruct the system to Kick all of the VMs
KICK_VMS=${KICK_VMS:-true}
[[ "${KICK_VMS}" = true ]] && source kick-vms.sh

# Instruct the system to deploy OpenStack Ansible
DEPLOY_OSA=${DEPLOY_OSA:-true}
[[ "${DEPLOY_OSA}" = true ]] && source osa-deploy.sh

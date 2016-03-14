OpenStack-Ansible Multi-Node AIO
################################
:date: 2016-03-09
:tags: rackspace, openstack, ansible
:category: \*openstack, \*nix


About this repository
---------------------

Full OpenStack deployment using a single OnMetal host from the
Rackspace Public Cloud. This is a multi-node installation using
VMs that have been PXE booted which was done to provide an environment
that is almost exactly what is in production. This script will build, kick
and deploy OpenStack using KVM, Cobbler, OpenStack-Ansible within 9 Nodes
and 1 load balancer all using a Hyper Converged environment.


Process
-------

Once you create your server,

Create at least one physical host that has public network access and is running the
Ubuntu 14.04 LTS (Trusty Tahr) Operating system. This script assumes that you have
an unpartitioned device with at least 1TB of storage. If youre using the Rackspace
OnMetal servers the drive partitioning will be done for you by detecting the largest
unpartitioned device. If you're doing the deployment on something other than a Rackspace
OnMetal server you may need to modify the ``build.sh`` script to do the needful in your
environment.

When your ready to build run the ``build.sh`` script by executing ``bash ./build.sh``.
The build script current executes a deployment of OpenStack Ansible using the master
branch. If you want to do something other than deploy master edit the bottom of the
script to suit your purposes.


Post Deployment
---------------

Once deployed you can use virt-manager to manage the KVM instances on the host, similar to a drac or ilo.

LINUX:
    If you're running a linux system as your workstation simply install virt-manager
    from your package manager and connect to the host via QEMU/KVM:SSH

OSX:
    If you're running a MAC you can get virt-manager via X11 forwarding to the host
    or install it via BREW. http://stackoverflow.com/questions/3921814/is-there-a-virt-manager-alternative-for-mac-os-x

WINDOWS:
    If you're running Windows, you can install virt-viewer from the KVM Download site.
    https://virt-manager.org/download/


Notes
-----

The cobbler and pre-seed setup has been implemented using some of the awesome work originally created by James Thorne

  * cobbler installation post - https://thornelabs.net/2015/11/26/install-and-configure-cobbler-on-ubuntu-1404.html
  * pre-seeds -- https://github.com/jameswthorne/preseeds-rpc


Options
-------

Set the default preseed device name. This is being set because sda is on hosts, vda is kvm, xvda is xen:
  ``DEVICE_NAME="${DEVICE_NAME:-vda}"``

This is set to instruct the preseed what the default network is expected to be:
  ``DEFAULT_NETWORK="${DEFAULT_NETWORK:-eth0}"``

Enable partitioning of the "${DATA_DISK_DEVICE}":
  ``PARTITION_HOST=${PARTITION_HOST:-true}``

Set the data disk device, if unset the largest unpartitioned device will be used to for host VMs:
  ``DATA_DISK_DEVICE="${DATA_DISK_DEVICE:-$(lsblk -brndo NAME,TYPE,FSTYPE,RO,SIZE | awk '/d[b-z]+ disk +0/{ if ($4>m){m=$4; d=$1}}; END{print d}')}"``

Instruct the system to deploy OpenStack Ansible:
  ``DEPLOY_OSA=${DEPLOY_OSA:-true}``

Set the OSA branch for this script to deploy:
  ``OSA_BRANCH=${OSA_BRANCH:-master}``
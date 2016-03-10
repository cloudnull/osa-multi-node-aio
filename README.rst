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


This script assumes that the environment is a using the following details  

  * FLAVOR: onmetal-io1
  * IMAGE: OnMetal - Ubuntu 14.04 LTS (Trusty Tahr)


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


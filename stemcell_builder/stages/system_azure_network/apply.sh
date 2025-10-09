#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

# Remove persistent device names so that eth0 comes up as eth0
rm -fr $chroot/etc/udev/rules.d/70-persistent-net.rules

# Context on the need to replace the hostname is here:
# https://github.com/cloudfoundry/bosh/issues/1399
echo -n "bosh-stemcell" > $chroot/etc/hostname

# The port 65330 is unusable on Azure
cp $dir/assets/90-azure-sysctl.conf $chroot/etc/sysctl.d
chmod 0644 $chroot/etc/sysctl.d/90-azure-sysctl.conf

# Configure Azure accelerated networking drivers to be unmanaged by systemd
# https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview?tabs=ubuntu#configure-drivers-to-be-unmanaged
mkdir -p $chroot/etc/systemd/network
cp $dir/assets/networkd/01-azure-unmanaged-sriov.network $chroot/etc/systemd/network
chmod 0644 $chroot/etc/systemd/network/01-azure-unmanaged-devices.network

cp $dir/assets/udev/10-azure-unmanaged-sriov.rules $chroot/etc/udev/rules.d
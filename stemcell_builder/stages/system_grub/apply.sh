#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

# Install both unsigned and signed GRUB packages.
# The unsigned grub-efi-amd64-bin is used for most infrastructures.
# The signed shim-signed and grub-efi-amd64-signed are used for Azure Trusted Launch with Secure Boot.
# The image_install_grub stage will select the appropriate binaries based on infrastructure.
#
# Azure Trusted Launch with Secure Boot requires signed bootloader chain:
# UEFI -> shim (Microsoft-signed) -> GRUB (Canonical-signed) -> kernel (Canonical-signed)
pkg_mgr install grub2 grub-efi-amd64-bin grub-efi-amd64-signed shim-signed

# When a kernel is installed, update-grub is run per /etc/kernel-img.conf.
# It complains when /boot/grub/menu.lst doesn't exist, so create it.
mkdir -p $chroot/boot/grub
touch $chroot/boot/grub/menu.lst

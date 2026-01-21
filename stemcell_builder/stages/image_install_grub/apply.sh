#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

disk_image=${work}/${stemcell_image_name}
image_mount_point=${work}/mnt

kpartx -dv ${disk_image}

# note: if the above kpartx command fails, it's probably because the loopback device needs to be unmapped.
# in that case, try this: sudo dmsetup remove loop0p1

# Map partition in image to loopback
device=$(losetup --show --find ${disk_image})
add_on_exit "losetup --verbose --detach ${device}"

device_partition_efi=$(kpartx -sav ${device} | cut -d" " -f3 | head -1)
device_partition_root=$(kpartx -sav ${device} | cut -d" " -f3 | tail -1)
add_on_exit "kpartx -dv ${device}"

loopback_efi_dev="/dev/mapper/${device_partition_efi}"
loopback_root_dev="/dev/mapper/${device_partition_root}"

# Mount partition
image_mount_point=${work}/mnt

mkdir -p ${image_mount_point}
mount ${loopback_root_dev} ${image_mount_point}
add_on_exit "umount ${image_mount_point}"

mkdir -p ${image_mount_point}/boot/efi
mount ${loopback_efi_dev} ${image_mount_point}/boot/efi
add_on_exit "umount ${image_mount_point}/boot/efi"

# == Guide to variables in this script (all paths are defined relative to the real root dir, not the chroot)

# Generate random password
random_password=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)

touch ${image_mount_point}${device}
mount --bind ${device} ${image_mount_point}${device}
add_on_exit "umount ${image_mount_point}${device}"

mkdir -p `dirname ${image_mount_point}${loopback_root_dev}`
touch ${image_mount_point}${loopback_root_dev}
mount --bind ${loopback_root_dev} ${image_mount_point}${loopback_root_dev}
add_on_exit "umount ${image_mount_point}${loopback_root_dev}"

mkdir -p `dirname ${image_mount_point}${loopback_efi_dev}`
touch ${image_mount_point}${loopback_efi_dev}
mount --bind ${loopback_efi_dev} ${image_mount_point}${loopback_efi_dev}
add_on_exit "umount ${image_mount_point}${loopback_efi_dev}"

# GRUB 2 needs /sys and /proc to do its job
mount -t proc none ${image_mount_point}/proc
add_on_exit "umount ${image_mount_point}/proc"

mount -t sysfs none ${image_mount_point}/sys
add_on_exit "umount ${image_mount_point}/sys"

echo "(hd0) ${device}" > ${image_mount_point}/boot/grub/device.map
echo "(hd0) ${device}" > ${image_mount_point}/device.map # fallback for non-UEFI systems

if [ "${stemcell_infrastructure}" == "azure" ]; then
  # Azure Gen2 VMs with Trusted Launch use UEFI Secure Boot
  # Install signed shim and GRUB to the EFI System Partition
  # Boot chain: UEFI -> shimx64.efi (Microsoft-signed) -> grubx64.efi (Canonical-signed) -> kernel

  mkdir -p ${image_mount_point}/boot/efi/EFI/BOOT
  mkdir -p ${image_mount_point}/boot/efi/EFI/ubuntu

  # Copy signed shim to the default EFI boot path (BOOTX64.EFI)
  cp ${image_mount_point}/usr/lib/shim/shimx64.efi.signed.latest ${image_mount_point}/boot/efi/EFI/BOOT/BOOTX64.EFI

  # Copy MOK manager (mmx64) - optional but useful for key management
  if [ -f ${image_mount_point}/usr/lib/shim/mmx64.efi.signed ]; then
    cp ${image_mount_point}/usr/lib/shim/mmx64.efi.signed ${image_mount_point}/boot/efi/EFI/BOOT/mmx64.efi
  elif [ -f ${image_mount_point}/usr/lib/shim/mmx64.efi ]; then
    cp ${image_mount_point}/usr/lib/shim/mmx64.efi ${image_mount_point}/boot/efi/EFI/BOOT/mmx64.efi
  fi

  # Copy signed GRUB - shim looks for grubx64.efi in the same directory or EFI/ubuntu/
  cp ${image_mount_point}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ${image_mount_point}/boot/efi/EFI/BOOT/grubx64.efi
  cp ${image_mount_point}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ${image_mount_point}/boot/efi/EFI/ubuntu/grubx64.efi

  # No legacy BIOS install for Azure Gen2 (UEFI-only)
else
  # install bootsector into disk image file
  run_in_chroot ${image_mount_point} "grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot/efi/EFI --removable -v --no-floppy ${device}"
  run_in_chroot ${image_mount_point} "grub-install -v --target=i386-pc  --grub-mkdevicemap=/device.map --no-floppy ${device}" # fallback for non-UEFI systems
fi

grub_suffix=""
case "${stemcell_infrastructure}" in
aws)
  grub_suffix="nvme_core.io_timeout=4294967295"
  ;;
azure)
  grub_suffix="nvme_core.io_timeout=240"
  ;;
cloudstack)
  grub_suffix="console=hvc0"
  ;;
esac

cat >${image_mount_point}/etc/default/grub <<EOF
GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor ${grub_suffix}"
EOF

# we use a random password to prevent user from editing the boot menu
pbkdf2_password=`run_in_chroot ${image_mount_point} "echo -e '${random_password}\n${random_password}' | grub-mkpasswd-pbkdf2 | grep -Eo 'grub.pbkdf2.sha512.*'"`
echo "\
cat << EOF
set superusers=vcap
password_pbkdf2 vcap $pbkdf2_password
EOF" >> ${image_mount_point}/etc/grub.d/00_header

# Setup menuentry
sed -i -e 's/--class os/--class os --unrestricted/g' ${image_mount_point}/etc/grub.d/10_linux

# assemble config file that is read by grub2 at boot time
if [ "${stemcell_infrastructure}" == "azure" ]; then
  # For Azure with signed GRUB, config must be at /boot/grub/grub.cfg
  # The signed grubx64.efi looks for config at $prefix/grub.cfg where prefix defaults to /boot/grub
  run_in_chroot ${image_mount_point} "GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/grub/grub.cfg"
else
  run_in_chroot ${image_mount_point} "GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg"
  run_in_chroot ${image_mount_point} "GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/grub/grub.cfg" # fallback for non-UEFI systems
fi

# Figure out uuid of partition
uuid_efi=$(blkid -c /dev/null -sUUID -ovalue ${loopback_efi_dev})
uuid_root=$(blkid -c /dev/null -sUUID -ovalue ${loopback_root_dev})
kernel_version=$(basename $(ls -rt ${image_mount_point}/boot/vmlinuz-* |tail -1) |cut -f2-8 -d'-')
initrd_file="initrd.img-${kernel_version}"
os_name=$(source ${image_mount_point}/etc/lsb-release ; echo -n ${DISTRIB_DESCRIPTION})

# set the correct root filesystem; use the ext2 filesystem's UUID
if [ "${stemcell_infrastructure}" == "azure" ]; then
  sed -i s%root=${loopback_root_dev}%root=UUID=${uuid_root}%g ${image_mount_point}/boot/grub/grub.cfg

  # Create redirect grub.cfg in EFI partition for signed GRUB
  # The signed grubx64.efi has $prefix hardcoded to (hd0,gpt1)/EFI/ubuntu
  # This redirect tells it to find the real grub.cfg on the root partition
  cat > ${image_mount_point}/boot/efi/EFI/ubuntu/grub.cfg <<GRUB_REDIRECT
search.fs_uuid ${uuid_root} root
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
GRUB_REDIRECT
else
  sed -i s%root=${loopback_root_dev}%root=UUID=${uuid_root}%g ${image_mount_point}/boot/efi/EFI/grub/grub.cfg
  sed -i s%root=${loopback_root_dev}%root=UUID=${uuid_root}%g ${image_mount_point}/boot/grub/grub.cfg # fallback for non-UEFI systems
fi

rm ${image_mount_point}/boot/grub/device.map
rm ${image_mount_point}/device.map

cat > ${image_mount_point}/etc/fstab <<FSTAB
# /etc/fstab Created by BOSH Stemcell Builder
UUID=${uuid_efi} /boot/efi vfat umask=0177 1 1
UUID=${uuid_root} / ext4 defaults 1 1
FSTAB


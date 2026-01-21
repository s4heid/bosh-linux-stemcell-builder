#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

disk_image=${work}/${stemcell_image_name}

# image_create_disk_size is in MiB
dd if=/dev/null of=${disk_image} bs=1M seek=${image_create_disk_size} 2> /dev/null

if [ "${stemcell_infrastructure}" == "azure" ]; then
  # Azure Gen2 VMs with Trusted Launch require UEFI boot with Secure Boot.
  # UEFI's native partition format is GPT (GUID Partition Table), which provides:
  # - Proper EFI System Partition support required for signed bootloader chain
  # - 64-bit LBA addressing (vs 32-bit in MBR)
  # References:
  # - https://uefi.org/specs/UEFI/2.10/05_GUID_Partition_Table_Format.html
  # - https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2
  #
  # For backward compatibility with older Azure CPIs that create Gen1 (BIOS) VMs,
  # we include a BIOS Boot Partition. GPT disks don't have the "MBR gap" that GRUB
  # uses on MBR disks, so a dedicated partition is needed for GRUB's core.img.
  # Partition layout: 1=BIOS Boot (1MiB), 2=ESP (50MiB), 3=Root (remaining)
  parted --script ${disk_image} mklabel gpt
  parted --script ${disk_image} mkpart bios_grub 1MiB 2MiB
  parted --script ${disk_image} set 1 bios_grub on
  parted --script ${disk_image} mkpart esp fat32 2MiB 52MiB
  parted --script ${disk_image} set 2 esp on
  parted --script ${disk_image} mkpart root ext4 52MiB 100%
else
  parted --script ${disk_image} mklabel msdos
  parted --script ${disk_image} mkpart primary fat32 0% 49MiB
  parted --script ${disk_image} set 1 esp on
  parted --script ${disk_image} mkpart primary ext2 50MiB 100%
fi

# unmap the loop device in case it's already mapped
timeout 100 bash -c "
until kpartx -dv ${disk_image}; do
  echo 'Waiting for loop device to be free'
  echo 'Running lsof'
  lsof ${disk_image}
  sleep 1
done
"

# Map partition in image to loopback
device=$(losetup --show --find ${disk_image})
add_on_exit "losetup --verbose --detach ${device}"

kpartx_output=$(kpartx -sav ${device})
add_on_exit "kpartx -dv ${device}"

if [ "${stemcell_infrastructure}" == "azure" ]; then
  # GPT layout: partition 1=BIOS Boot, 2=ESP, 3=Root
  device_partition_efi=$(echo "$kpartx_output" | cut -d" " -f3 | sed -n '2p')
  device_partition_root=$(echo "$kpartx_output" | cut -d" " -f3 | sed -n '3p')
else
  # MBR layout: partition 1=ESP, 2=Root
  device_partition_efi=$(echo "$kpartx_output" | cut -d" " -f3 | head -1)
  device_partition_root=$(echo "$kpartx_output" | cut -d" " -f3 | tail -1)
fi

loopback_efi_dev="/dev/mapper/${device_partition_efi}"
loopback_root_dev="/dev/mapper/${device_partition_root}"

# Format the partitions
mkfs.vfat ${loopback_efi_dev}
mkfs.ext4 ${loopback_root_dev}

# Mount partition
image_mount_point=${work}/mnt

mkdir -p ${image_mount_point}
mount ${loopback_root_dev} ${image_mount_point}
add_on_exit "umount ${image_mount_point}"

mkdir -p ${image_mount_point}/boot/efi
mount ${loopback_efi_dev} ${image_mount_point}/boot/efi
add_on_exit "umount ${image_mount_point}/boot/efi"

# Copy root, don't cross mount-points, skipping /boot/efi is okay; it's empty
time rsync -aHA $chroot/ ${image_mount_point}
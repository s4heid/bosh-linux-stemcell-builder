#!/bin/bash -eux

if [ -t 0 ]; then
  echo 'USAGE: $0 <<< mounted-image-directory'
  echo 'example: echo /tmp/chroot | unmount-image.sh'
  exit 2
fi

mounted_image_directory=$(cat)

sleep 10

umount "$mounted_image_directory" >/dev/null || true

sleep 10

raw_disk=$(losetup -l | grep 'disk.raw' | tail -n1 | awk '{ print $6 }')
kpartx -d "$raw_disk" >/dev/null || true

echo "$raw_disk"

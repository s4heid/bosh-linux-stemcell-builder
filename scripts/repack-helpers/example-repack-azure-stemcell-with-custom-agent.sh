#!/bin/bash -eux

set -o pipefail

path=$(dirname $0)

if [[ $# != 2 ]];then
  echo "USAGE: $0 [stemcell] [version]"
fi

bosh_agent=./tmp/bosh-agent
if [[ ! -f "$bosh_agent" ]]; then
  echo "BOSH agent binary not found: $bosh_agent"
  exit 1
fi

stemcell=$1
version=$2
stemcell_path=$($path/extract-stemcell.sh $stemcell)

cleanup_dirs=$(mktemp)
cleanup() {
  for dir in $(cat $cleanup_dirs); do
    rm -rf $dir
  done
}

trap cleanup EXIT

image_path=$(echo $stemcell_path | \
  $path/extract-image.sh | \
  $path/convert-vhd-to-raw.sh | \
  $path/mount-image.sh | \
  $path/update-file.sh "$bosh_agent" /var/vcap/bosh/bin/bosh-agent | \
  $path/unmount-image.sh | \
  $path/convert-raw-to-vhd.sh)


new_stemcell=$($path/pack-stemcell.sh "$stemcell_path" "$image_path" "$version")

mkdir -p ~/workspace/landscape-tss-bosh
cp "$new_stemcell/stemcell.tgz" ~/workspace/landscape-tss-bosh/stemcell-"$version".tgz
chown c5377406:acg_standardusers ~/workspace/landscape-tss-bosh/stemcell-"$version".tgz
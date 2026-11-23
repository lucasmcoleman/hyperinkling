#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ( "$1" != stable && "$1" != batching ) ]]; then
  echo "Usage: bash scripts/fetch-source.sh {stable|batching} DESTINATION" >&2
  exit 2
fi

mode=$1
destination=$2
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patches="$repo/patches"
upstream=https://github.com/alesha-pro/maya-inkling-mini.git
revision=e819852f822479af783638a467bfdfe2ed6882ec

if [[ -e "$destination" || -L "$destination" ]]; then
  echo "Destination must be a new directory: $destination" >&2
  exit 1
fi

parent=$(dirname -- "$destination")
mkdir -p -- "$parent"
staging=$(mktemp -d -- "$parent/.maya-source.XXXXXXXX")
trap 'if [[ -d "$staging" ]]; then rm -rf -- "$staging"; fi' EXIT

git init -q "$staging"
git -C "$staging" fetch --no-tags --depth=1 "$upstream" "$revision"
[[ $(git -C "$staging" rev-parse FETCH_HEAD) == "$revision" ]]
git -C "$staging" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
git -C "$staging" apply --index "$patches/0001-mainline-gguf.patch"
if [[ "$mode" == batching ]]; then
  git -C "$staging" apply --index "$patches/0002-experimental-batched-serving.patch"
fi

mv -Tn -- "$staging" "$destination"
if [[ -d "$staging" ]]; then
  echo "Destination appeared while fetching Maya: $destination" >&2
  exit 1
fi

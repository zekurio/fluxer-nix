#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix
# Pins fluxer-desktop to the newest stable Linux build.
#
# The version and tarball checksums come from the feed the app itself polls
# for updates. Each checksum is cross-checked against the digest GitHub
# reports for the release asset the package downloads.
set -euo pipefail

sources=${1:-$(git rev-parse --show-toplevel)/pkgs/fluxer-desktop/sources.json}
feed=https://pkgs.fluxer.com/desktop/stable/linux

# GitHub allows few unauthenticated API requests per address, and CI runners
# share addresses.
auth=()
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

current=$(jq -r .version "$sources")
version=
declare -A hashes

for system in $(jq -r '.platforms | keys[]' "$sources"); do
  arch=$(jq -r --arg s "$system" '.platforms[$s].arch' "$sources")
  latest=$(curl -fsSL "$feed/$arch/latest")
  v=$(jq -r .version <<<"$latest")
  sha256=$(jq -r .files.tar_gz.sha256 <<<"$latest")

  if [[ -z $version ]]; then
    version=$v
  elif [[ $v != "$version" ]]; then
    echo "The feed lists $version for one architecture and $v for $arch, try again later." >&2
    exit 1
  fi

  asset="Fluxer-$v-linux-$arch.tar.gz"
  digest=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/fluxerapp/fluxer/releases/tags/fluxer-desktop-stable@$v" \
    | jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest')
  if [[ $digest != "sha256:$sha256" ]]; then
    echo "GitHub reports '$digest' for $asset, the feed says sha256:$sha256." >&2
    exit 1
  fi

  hashes[$system]=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$sha256")
done

if [[ $version == "$current" ]]; then
  echo "fluxer-desktop is already at $version"
  exit 0
fi

updated=$(jq --arg v "$version" '.version = $v' "$sources")
for system in "${!hashes[@]}"; do
  updated=$(jq --arg s "$system" --arg h "${hashes[$system]}" '.platforms[$s].hash = $h' <<<"$updated")
done
printf '%s\n' "$updated" >"$sources"

echo "fluxer-desktop: $current -> $version"

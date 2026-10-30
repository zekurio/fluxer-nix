#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix
# Pins the newest Fluxer server release in release.json.
#
# Upstream publishes every release as fluxer-release@<version> with a manifest
# that names the version and source commit of each component image. A
# component that was not rebuilt keeps the image, and so the commit, of an
# earlier release, so one release can span several commits. Each component
# here builds from the commit upstream built its image from.
#
# Dependency hashes (Cargo vendor directories, pnpm stores) are refetched for
# every component whose commit changed. To do that, the script blanks the hash,
# builds the fetcher and reads the hash Nix reports.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
release_file=${1:-$root/pkgs/fluxer/release.json}
repo=fluxerapp/fluxer

# The components this flake builds. fluxer-app-proxy is the variant of
# fluxer-app-proxy-self-hosted for the official instance, and the docs site is
# not part of an instance.
components='[
  "fluxer-admin", "fluxer-api", "fluxer-app-proxy-self-hosted", "fluxer-gateway",
  "fluxer-gifs", "fluxer-media-proxy", "fluxer-messages", "fluxer-push",
  "fluxer-snowflakes", "fluxer-static", "fluxer-unfurl", "fluxer-users"
]'

# Fixed-output dependencies, as "<component> <hash key> <flake attribute>".
deps=(
  "fluxer-admin cargoDeps fluxer-admin.cargoDeps"
  "fluxer-api pnpmDeps fluxer-api.pnpmDeps"
  "fluxer-app-proxy-self-hosted cargoDeps fluxer-app-proxy.cargoDeps"
  "fluxer-app-proxy-self-hosted libfluxcoreCargoDeps fluxer-web.libfluxcoreCargoDeps"
  "fluxer-app-proxy-self-hosted libfluxwebpCargoDeps fluxer-web.libfluxwebpCargoDeps"
  "fluxer-app-proxy-self-hosted pnpmDeps fluxer-web.pnpmDeps"
  "fluxer-gateway cargoDeps fluxer-gateway.cargoDeps"
  "fluxer-gateway rebarDeps fluxer-gateway.rebarDeps"
  "fluxer-gateway memberListNifCargoDeps fluxer-gateway.memberListNifCargoDeps"
  "fluxer-gateway markdownNifCargoDeps fluxer-gateway.markdownNifCargoDeps"
  "fluxer-gifs cargoDeps fluxer-gifs.cargoDeps"
  "fluxer-media-proxy cargoDeps fluxer-media-proxy.cargoDeps"
  "fluxer-messages cargoDeps fluxer-messages.cargoDeps"
  "fluxer-push cargoDeps fluxer-push.cargoDeps"
  "fluxer-snowflakes cargoDeps fluxer-snowflakes.cargoDeps"
  "fluxer-static spellcheckDictionaries fluxer-static.spellcheckDictionaries"
  "fluxer-unfurl cargoDeps fluxer-unfurl.cargoDeps"
  "fluxer-users cargoDeps fluxer-users.cargoDeps"
)

tag=$(
  curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=100" \
    | jq -r '[.[] | select((.tag_name | startswith("fluxer-release@")) and (.draft | not) and (.prerelease | not))]
      | if length == 0 then error("no fluxer-release in the last 100 releases") else max_by(.published_at).tag_name end'
)
version=${tag#fluxer-release@}
manifest=$(curl -fsSL "https://github.com/$repo/releases/download/fluxer-release%40$version/fluxer-release-$version.json")

old=$(cat "$release_file" 2>/dev/null || echo '{"components": {}}')
old_version=$(jq -r '.version // "none"' <<<"$old")

next=$(
  jq --argjson want "$components" --argjson old "$old" '
    ([.components[].component] as $have | $want - $have) as $missing
    | if ($missing | length) > 0 then error("release lacks \($missing | join(", "))") else . end
    | {
        version,
        components: ([
          .components[]
          | select(.component as $c | $want | index($c))
          | .component as $c
          | {
              key: $c,
              value: {
                version: .build_version,
                rev: .source_sha,
                # Keep the hashes of a component whose commit did not change.
                hashes: (if $old.components[$c].rev == .source_sha then $old.components[$c].hashes else {} end)
              }
            }
        ] | from_entries)
      }' <<<"$manifest"
)

# Source hashes, prefetched once per commit.
declare -A src_hashes
for rev in $(jq -r '[.components[] | select(.hashes.src == null) | .rev] | unique | .[]' <<<"$next"); do
  src_hashes[$rev]=$(nix flake prefetch --json "github:$repo/$rev" | jq -r .hash)
done
for rev in "${!src_hashes[@]}"; do
  next=$(jq --arg rev "$rev" --arg hash "${src_hashes[$rev]}" \
    '.components |= map_values(if .rev == $rev and .hashes.src == null then .hashes.src = $hash else . end)' <<<"$next")
done

jq . <<<"$next" >"$release_file"

for dep in "${deps[@]}"; do
  read -r component key attr <<<"$dep"
  if jq -e --arg c "$component" --arg k "$key" '(.components[$c].hashes[$k] // "") != ""' "$release_file" >/dev/null; then
    continue
  fi
  # Components on the same commit share the workspace's Cargo vendor
  # directory. Other keys only share a name: the API's and the web app's
  # pnpmDeps hold different workspaces.
  hash=""
  if [ "$key" = cargoDeps ]; then
    hash=$(jq -r --arg c "$component" \
      '.components[$c].rev as $rev | [.components[] | select(.rev == $rev) | .hashes.cargoDeps // empty | select(. != "")] | first // empty' \
      "$release_file")
  fi
  if [ -z "$hash" ]; then
    # An empty hash makes Nix fetch and print the real one.
    jq --arg c "$component" --arg k "$key" '.components[$c].hashes[$k] = ""' "$release_file" >"$release_file.tmp"
    mv "$release_file.tmp" "$release_file"
    hash=$( (nix build --no-link "$root#$attr" 2>&1 || true) | sed -nE 's/^ *got: *(sha256-[^ ]+)$/\1/p' | tail -n1)
  fi
  if [ -z "$hash" ]; then
    echo "could not determine the hash of $attr" >&2
    exit 1
  fi
  jq --arg c "$component" --arg k "$key" --arg h "$hash" '.components[$c].hashes[$k] = $h' "$release_file" >"$release_file.tmp"
  mv "$release_file.tmp" "$release_file"
done

if [ "$old_version" = "$version" ]; then
  echo "fluxer: already at $version"
else
  echo "fluxer: $old_version -> $version"
fi

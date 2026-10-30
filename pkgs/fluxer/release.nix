# The pinned Fluxer server release. See update.sh.
{
  lib,
  fetchFromGitHub,
  rustPlatform,
}:

let
  release = lib.importJSON ./release.json;
in
{
  inherit (release) version;

  # The version, commit, hashes and source tree of one upstream component.
  component =
    name:
    let
      c = release.components.${name} or (throw "fluxer: release.json has no component ${name}");
      src = fetchFromGitHub {
        owner = "fluxerapp";
        repo = "fluxer";
        inherit (c) rev;
        hash = c.hashes.src;
      };
    in
    {
      inherit name src;
      inherit (c) version rev hashes;

      # The crates of the root Cargo workspace. Components on the same commit
      # share one vendor directory.
      cargoDeps = rustPlatform.fetchCargoVendor {
        name = "fluxer-cargo";
        inherit src;
        hash = c.hashes.cargoDeps;
      };

      # The crates of a crate outside the workspace, with its own lockfile.
      cargoDepsFor =
        key: cargoRoot:
        rustPlatform.fetchCargoVendor {
          name = "fluxer-${key}";
          inherit src cargoRoot;
          hash = c.hashes.${key};
        };
    };
}

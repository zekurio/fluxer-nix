# Builds one crate of the Rust workspace from the commit of its component.
{
  lib,
  rustPlatform,
  aws-lc,
  pkg-config,
  fluxerRelease,
}:

{
  pname,
  component,
  crate,
  features ? [ ],
  description,
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  ...
}@args:

let
  c = fluxerRelease.component component;
in
rustPlatform.buildRustPackage (
  removeAttrs args [
    "component"
    "crate"
    "features"
    "description"
  ]
  // {
    inherit pname;
    inherit (c) version src cargoDeps;

    # rustls uses aws-lc-rs. cargoSetupHook sets AWS_LC_SYS_USE_SYSTEM=1, so
    # aws-lc-sys finds this one with pkg-config instead of building its
    # vendored copy.
    nativeBuildInputs = [ pkg-config ] ++ nativeBuildInputs;
    buildInputs = [ aws-lc ] ++ buildInputs;

    cargoBuildFlags = [
      "-p"
      crate
    ]
    ++ lib.optionals (features != [ ]) [
      "--features"
      (lib.concatStringsSep "," features)
    ];
    # The tests need Postgres, NATS and the other services.
    doCheck = false;

    meta = {
      inherit description;
      homepage = "https://fluxer.app";
      license = lib.licenses.agpl3Plus;
      platforms = lib.platforms.linux;
      mainProgram = crate;
    };
  }
)

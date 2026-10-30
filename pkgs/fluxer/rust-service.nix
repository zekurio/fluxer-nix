# Builds one crate of the Rust workspace from the commit of its component.
{
  lib,
  rustPlatform,
  fluxerRelease,
}:

{
  pname,
  component,
  crate,
  features ? [ ],
  description,
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

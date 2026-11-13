# Upstream's build tool. The web app and gateway builds call it through
# tools/ci/run.sh, which would otherwise build it with cargo on every run.
{
  rustPlatform,
  aws-lc,
  pkg-config,
  component,
}:

rustPlatform.buildRustPackage {
  pname = "fluxer-ci";
  inherit (component) version src cargoDeps;

  # See rust-service.nix.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ aws-lc ];

  cargoBuildFlags = [
    "-p"
    "fluxer-ci"
  ];
  doCheck = false;

  meta.mainProgram = "fluxer-ci";
}

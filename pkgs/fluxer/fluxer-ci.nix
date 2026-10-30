# Upstream's build tool. The web app and gateway builds call it through
# tools/ci/run.sh, which would otherwise build it with cargo on every run.
{ rustPlatform, component }:

rustPlatform.buildRustPackage {
  pname = "fluxer-ci";
  inherit (component) version src cargoDeps;

  cargoBuildFlags = [
    "-p"
    "fluxer-ci"
  ];
  doCheck = false;

  meta.mainProgram = "fluxer-ci";
}

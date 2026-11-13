{
  lib,
  stdenv,
  callPackage,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_26,
  cargo,
  rustc,
  lld,
  llvmPackages,
  wasm-bindgen-cli_0_2_128,
  brotli,
  fluxerRelease,
}:

let
  # The web app ships inside the self-hosted app-proxy image.
  component = fluxerRelease.component "fluxer-app-proxy-self-hosted";
  inherit (component) hashes;

  fluxer-ci = callPackage ../fluxer/fluxer-ci.nix { inherit component; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "fluxer-web";
  inherit (component) version src;

  # The same install the upstream image does.
  pnpmWorkspaces = [ "fluxer_app..." ];
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      pnpmWorkspaces
      ;
    pnpm = pnpm_11;
    fetcherVersion = 5;
    hash = hashes.pnpmDeps;
  };

  # The WASM step builds three crates of the root workspace: the markdown
  # parser, libfluxcore and libfluxwebp.
  inherit (component) cargoDeps;

  nativeBuildInputs = [
    brotli
    cargo
    lld
    nodejs_26
    pnpmConfigHook
    pnpm_11
    rustc
    wasm-bindgen-cli_0_2_128
  ];

  env = {
    BUILD_VERSION = finalAttrs.version;
    FLUXER_CI_BIN = lib.getExe fluxer-ci;
    # The C parts of libfluxwebp and libfluxcore. The wrapped compiler adds
    # flags for the host.
    CC_wasm32_unknown_unknown = "${llvmPackages.clang-unwrapped}/bin/clang";
    AR_wasm32_unknown_unknown = "${llvmPackages.llvm}/bin/llvm-ar";
    NODE_OPTIONS = "--max-old-space-size=8192";
  };

  postPatch = ''
    patchShebangs tools/ci/run.sh fluxer_app_proxy/scripts
  '';

  postConfigure = ''
    # Not cargoSetupHook: it sets ZSTD_SYS_USE_PKG_CONFIG and other switches
    # to system libraries, which break the WASM build.
    export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
    mkdir -p "$CARGO_HOME"
    cat >"$CARGO_HOME/config.toml" <<EOF
    [source.crates-io]
    replace-with = "vendored"

    [source.vendored]
    directory = "$cargoDeps/source-registry-0"

    [net]
    offline = true
    EOF
  '';

  buildPhase = ''
    runHook preBuild
    pnpm --dir fluxer_app run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r fluxer_app/dist $out
    sh fluxer_app_proxy/scripts/precompress_assets.sh $out
    runHook postInstall
  '';

  passthru = { inherit fluxer-ci; };

  meta = {
    description = "Fluxer web app, as served by the self-hosted app proxy";
    homepage = "https://fluxer.app";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
  };
})

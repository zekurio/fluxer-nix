# The HTTP API and the background worker, which share one build.
{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_26,
  makeWrapper,
  fluxerRelease,
}:

let
  component = fluxerRelease.component "fluxer-api";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "fluxer-api";
  inherit (component) version src;

  # FLUXER_API_LISTEN_HOST, the address the API and the worker's metrics
  # server listen on. Upstream always listens on every address.
  patches = [ ./listen-host.patch ];

  pnpmWorkspaces = [ "fluxer_api..." ];
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      pnpmWorkspaces
      ;
    pnpm = pnpm_11;
    fetcherVersion = 5;
    hash = component.hashes.pnpmDeps;
  };

  nativeBuildInputs = [
    makeWrapper
    nodejs_26
    pnpmConfigHook
    pnpm_11
  ];

  buildPhase = ''
    runHook preBuild
    pnpm --filter fluxer_api run build
    runHook postBuild
  '';

  # esbuild bundles the workspace packages into dist/, so the API needs only
  # its npm dependencies at runtime. pnpm deploy, which upstream uses, needs
  # registry metadata the offline store lacks, so prune the install to
  # production dependencies and keep the tree pnpm links them from.
  installPhase = ''
    runHook preInstall

    # CI keeps pnpm from asking before it removes node_modules.
    CI=true pnpm install --offline --frozen-lockfile --ignore-scripts --prod --filter 'fluxer_api...'

    # The whole package, as pnpm deploy copies it: the API reads data files
    # such as src/api/words/*.txt at runtime.
    lib=$out/lib/fluxer
    mkdir -p $lib
    cp -r package.json node_modules tsconfigs fluxer_api $lib/
    rm -rf $lib/fluxer_api/pkgs
    # Links to workspace packages, which are bundled into dist/.
    find $lib -xtype l -delete

    for entry in api:AppEntrypoint worker:WorkerEntrypoint; do
      makeWrapper ${lib.getExe nodejs_26} $out/bin/fluxer-''${entry%%:*} \
        --chdir $lib/fluxer_api \
        --set-default NODE_ENV production \
        --add-flags "--enable-source-maps $lib/fluxer_api/dist/''${entry#*:}.js"
    done

    runHook postInstall
  '';

  meta = {
    description = "Fluxer HTTP API and background worker";
    homepage = "https://fluxer.app";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "fluxer-api";
  };
})

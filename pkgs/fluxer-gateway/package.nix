# The realtime gateway: an Erlang release with two Rust NIFs.
{
  lib,
  stdenv,
  callPackage,
  beamPackages,
  cargo,
  rustc,
  git,
  cacert,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  makeWrapper,
  zstd,
  fluxerRelease,
}:

let
  component = fluxerRelease.component "fluxer-gateway";
  inherit (beamPackages) erlang rebar3;

  fluxer-ci = callPackage ../fluxer/fluxer-ci.nix { inherit component; };

  # Plugins for formatting, linting and auditing. rebar3 would fetch them on
  # every run, and the release does not need them.
  dropProjectPlugins = ''
    sed -i '/^{project_plugins, \[/,/^\]}\./d' fluxer_gateway/rebar.config
  '';

  # Hex packages and the one git dependency, as rebar3 checkouts.
  rebarDeps = stdenv.mkDerivation {
    name = "fluxer-gateway-deps-${component.version}";
    inherit (component) src;
    nativeBuildInputs = [
      cacert
      erlang
      git
      rebar3
    ];
    postPatch = dropProjectPlugins + ''
      # The NIF build runs as a compile hook, not during get-deps.
      sed -i '/^{pre_hooks,/d' fluxer_gateway/rebar.config
    '';
    dontConfigure = true;
    buildPhase = ''
      cd fluxer_gateway
      HOME=$TMPDIR rebar3 get-deps
    '';
    installPhase = ''
      mkdir -p $out
      cp -r _build/default/lib/. $out/
      find $out -name .git -prune -exec rm -rf {} +
      rm -rf $out/fluxer_gateway
      # A git_subdir dependency lands one level down, where rebar3 does not
      # take it for a checkout.
      for dep in $out/*; do
        name=$(basename "$dep")
        if [ ! -e "$dep/src" ] && [ -d "$dep/$name/src" ]; then
          mv "$dep/$name" "$dep.flat"
          rm -r "$dep"
          mv "$dep.flat" "$dep"
        fi
      done
    '';
    dontFixup = true;
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    outputHashMode = "recursive";
    outputHash = component.hashes.rebarDeps;
    outputHashAlgo = if component.hashes.rebarDeps == "" then "sha256" else null;
  };
in
stdenv.mkDerivation {
  pname = "fluxer-gateway";
  inherit (component) version src;

  inherit rebarDeps;
  memberListNifCargoDeps = component.cargoDepsFor "memberListNifCargoDeps" "fluxer_gateway/native/guild_member_list_oset_nif";
  markdownNifCargoDeps = component.cargoDepsFor "markdownNifCargoDeps" "fluxer_gateway/native/push_markdown_plaintext_nif";

  nativeBuildInputs = [
    cargo
    erlang
    makeWrapper
    rebar3
    rustc
  ];

  env.FLUXER_CI_BIN = lib.getExe fluxer-ci;

  patches = [
    # The entrypoint writes the cookie to $HOME/.erlang.cookie in place of
    # vm.args, whose contents end up on the command line, where ps shows it.
    ./cookie-file.patch
    # FLUXER_ERLANG_DIST_INTERFACE, the address of the distribution port,
    # which defaults to every address as before.
    ./dist-interface.patch
    # The rollout config is fetched once, 2 s after start. If the API is not
    # up yet, the gateway keeps the defaults until the config next changes.
    ./retry-rollout-config.patch
  ];

  postPatch = dropProjectPlugins + ''
    patchShebangs tools/ci/run.sh
  '';

  configurePhase = ''
    runHook preConfigure

    mkdir -p "$NIX_BUILD_TOP/cargo-vendor"
    for deps in $memberListNifCargoDeps $markdownNifCargoDeps; do
      for crate in "$deps"/source-registry-0/*; do
        ln -sfn "$crate" "$NIX_BUILD_TOP/cargo-vendor/$(basename "$crate")"
      done
    done
    export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
    mkdir -p "$CARGO_HOME"
    cat >"$CARGO_HOME/config.toml" <<EOF
    [source.crates-io]
    replace-with = "vendored"

    [source.vendored]
    directory = "$NIX_BUILD_TOP/cargo-vendor"

    [net]
    offline = true
    EOF

    cd fluxer_gateway
    mkdir _checkouts
    cp -r $rebarDeps/. _checkouts/
    chmod -R u+w _checkouts
    patchShebangs _checkouts

    # ezstd's build clones zstd v1.5.7 and builds its static library, unless
    # the library is already there. nixpkgs' zstd source is that release.
    ezstd_zstd=_checkouts/ezstd/_build/deps/zstd
    mkdir -p $(dirname $ezstd_zstd)
    cp -r ${zstd.src} $ezstd_zstd
    chmod -R u+w $ezstd_zstd
    make -C $ezstd_zstd lib-release CFLAGS="-O2 -fPIC" -j$NIX_BUILD_CORES
    rm -f $ezstd_zstd/lib/*.so $ezstd_zstd/lib/*.so.*

    cp config/sys.config.template config/sys.config

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    HOME=$TMPDIR REBAR_OFFLINE=1 rebar3 as prod release
    runHook postBuild
  '';

  # Upstream's entrypoint sizes the schedulers, reads the cookie from
  # FLUXER_ERLANG_COOKIE_FILE into $HOME/.erlang.cookie and starts the release
  # in the foreground.
  installPhase = ''
    runHook preInstall

    rel=$out/lib/fluxer_gateway
    mkdir -p $out/lib $out/bin
    cp -r _build/prod/rel/fluxer_gateway $rel
    mv $rel/bin/fluxer_gateway $rel/bin/fluxer_gateway.real
    install -m755 scripts/fluxer_gateway_release_wrapper.sh $rel/bin/fluxer_gateway
    install -m755 scripts/docker_entrypoint.sh $out/bin/fluxer-gateway
    substituteInPlace $out/bin/fluxer-gateway \
      --replace-fail /opt/fluxer_gateway/node_name '"$RELX_OUT_FILE_PATH/node_name"' \
      --replace-fail /opt/fluxer_gateway/bin/fluxer_gateway $rel/bin/fluxer_gateway
    substituteInPlace $rel/bin/fluxer_gateway \
      --replace-fail '"$script_dir/../node_name"' '"$RELX_OUT_FILE_PATH/node_name"'
    patchShebangs $out/bin $rel/bin

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/fluxer-gateway \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          gawk
          gnugrep
          gnused
        ]
      }
  '';

  passthru = {
    inherit fluxer-ci;
    inherit (component) cargoDeps;
  };

  meta = {
    description = "Fluxer realtime gateway";
    homepage = "https://fluxer.app";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "fluxer-gateway";
  };
}

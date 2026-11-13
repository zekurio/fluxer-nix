{
  lib,
  stdenv,
  fetchurl,
  addDriverRunpath,
  asar,
  autoPatchelfHook,
  copyDesktopItems,
  makeDesktopItem,
  makeShellWrapper,
  wrapGAppsHook3,

  # Linked by the Electron binary and the native addons.
  alsa-lib,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libdrm,
  libfido2,
  libgbm,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  pipewire,
  systemdLibs,

  # Loaded with dlopen() at runtime.
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libva,
  pciutils,
  speechd-minimal,
  vulkan-loader,

  xdg-utils,

  # Extra Chromium/Fluxer switches, e.g. "--enable-features=VaapiVideoEncoder".
  commandLineArgs ? "",
  # Keep the client on the renderer bundled with this package. Upstream
  # otherwise downloads newer renderer modules into the user's data directory.
  disableUpdates ? true,
  # Text-to-speech through speech-dispatcher.
  withTTS ? true,
  # Hunspell dictionaries for spellchecking, e.g. [ hunspellDicts.en_US ].
  # Dictionaries in $XDG_DATA_DIRS/hunspell are picked up as well.
  hunspellDictionaries ? [ ],
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
  platform =
    sources.platforms.${stdenv.hostPlatform.system}
      or (throw "fluxer-desktop: unsupported system ${stdenv.hostPlatform.system}");

  pname = "fluxer-desktop";
  # Upstream's identifiers for the stable channel. The app derives its Wayland
  # app_id and X11 WM_CLASS from the desktop file name, and looks for that file
  # in $XDG_DATA_DIRS before it writes its own copy to ~/.local/share.
  desktopId = "app.fluxer.FluxerDesktop";
  iconName = "fluxer";

  tarball = "Fluxer-${version}-linux-${platform.arch}.tar.gz";

  optionalWrapperArgs =
    lib.optionals (hunspellDictionaries != [ ]) [
      "--prefix"
      "HUNSPELL_DICT_DIR"
      ":"
      (lib.makeSearchPath "share/hunspell" hunspellDictionaries)
    ]
    ++ lib.optionals withTTS [
      "--add-flags"
      "--enable-speech-dispatcher"
    ]
    ++ lib.optionals disableUpdates [
      "--add-flags"
      "--fluxer-disable-module-updates"
    ]
    ++ lib.optionals (commandLineArgs != "") [
      "--add-flags"
      commandLineArgs
    ];
in
stdenv.mkDerivation {
  inherit pname version;

  src = fetchurl {
    urls = [
      "https://github.com/fluxerapp/fluxer/releases/download/fluxer-desktop-stable%40${version}/${tarball}"
      "https://pkgs.fluxer.com/desktop/stable/linux/${platform.arch}/${version}/tar_gz"
    ];
    name = tarball;
    inherit (platform) hash;
  };

  nativeBuildInputs = [
    asar
    autoPatchelfHook
    copyDesktopItems
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libfido2
    libgbm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    pipewire
    (lib.getLib stdenv.cc.cc)
    systemdLibs
  ];

  # Chromium dlopen()s these. autoPatchelf adds them to the RUNPATH of the
  # executables.
  runtimeDependencies = map lib.getLib (
    [
      libGL
      libnotify
      libpulseaudio
      libsecret
      libva
      pciutils
      pipewire
      systemdLibs
    ]
    ++ lib.optional withTTS speechd-minimal
  );

  # GPU driver libraries, including libcuda and libnvidia-encode, which the
  # hardware-encoder addon loads for NVENC.
  appendRunpaths = [ "${addDriverRunpath.driverLink}/lib" ];

  dontConfigure = true;
  dontStrip = true;
  dontWrapGApps = true;

  buildPhase = ''
    runHook preBuild

    asar extract resources/app.asar app
    rm -r resources/app.asar resources/app.asar.unpacked

    # The WebAuthn addon ships its own libfido2, OpenSSL, libudev, zlib and
    # libcbor. Link it against the nixpkgs builds instead.
    rm app/node_modules/@fluxer/webauthn/lib*.so*

    # Upstream writes .desktop files for autostart (enabled by default on the
    # first launch) and the menu entry with process.execPath as the command.
    # Here that is the unwrapped binary in the store, which skips the wrapper
    # and stops existing after the next update. Use the command on $PATH.
    # Source builds set this with FLUXER_LAUNCH_COMMAND, which esbuild inlines
    # as an empty string in the release bundle:
    #   return getAppImagePath() ?? (PACKAGE_LAUNCH_COMMAND || process.execPath)
    launchPath='function ([A-Za-z_$][A-Za-z0-9_$]*)\(\)\{return ([A-Za-z_$][A-Za-z0-9_$]*)\(\)\?\?\([A-Za-z_$][A-Za-z0-9_$]*\|\|process\.execPath\)\}'
    # grep fails on no match, which under pipefail would end the build before
    # the message below.
    matches=$({ grep -rEo "$launchPath" app/dist/main || true; } | wc -l)
    if [ "$matches" -ne 1 ]; then
      echo "expected one Linux launch path function in the main bundle, found $matches" >&2
      exit 1
    fi
    grep -rlE "$launchPath" app/dist/main \
      | xargs sed -E -i "s/$launchPath/function \1(){return \2()??\"${pname}\"}/"

    # Same layout as upstream: native addons and the bundled renderer live
    # next to the archive in app.asar.unpacked.
    asar pack app resources/app.asar --unpack '*.node' --unpack-dir dist/renderer
    rm -r app
    test -f resources/app.asar.unpacked/dist/renderer/index.html
    test -n "$(find resources/app.asar.unpacked/node_modules -name '*.node')"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/${pname}
    cp -r . $out/opt/${pname}

    # A setuid helper cannot live in the store. Chromium uses user namespaces,
    # or the NixOS wrapper from security.chromiumSuidSandbox.
    rm $out/opt/${pname}/chrome-sandbox

    # The nixpkgs loader finds the ICDs under /run/opengl-driver.
    ln -sf ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/opt/${pname}/libvulkan.so.1

    for size in 16 24 32 48 64 128 256 512; do
      install -Dm644 resources/icons/''${size}x''${size}.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/${iconName}.png
    done

    runHook postInstall
  '';

  preFixup = ''
    makeShellWrapper $out/opt/${pname}/fluxer $out/bin/${pname} \
      "''${gappsWrapperArgs[@]}" \
      --prefix XDG_DATA_DIRS : "$out/share" \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
      ${lib.escapeShellArgs optionalWrapperArgs}
  '';

  desktopItems = [
    (makeDesktopItem {
      name = desktopId;
      desktopName = "Fluxer";
      genericName = "Instant Messenger";
      comment = "Instant messaging and VoIP";
      exec = "${pname} %U";
      tryExec = pname;
      icon = iconName;
      startupWMClass = desktopId;
      startupNotify = true;
      singleMainWindow = true;
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      keywords = [
        "chat"
        "im"
        "messaging"
        "messenger"
        "voip"
        "voice"
        "video"
        "call"
      ];
      mimeTypes = [ "x-scheme-handler/fluxer" ];
      actions = {
        open-settings = {
          name = "Open Settings";
          exec = "${pname} --fluxer-task=open-settings %U";
        };
        new-dm = {
          name = "New Direct Message";
          exec = "${pname} --fluxer-task=new-dm %U";
        };
      };
      extraConfig."X-GNOME-UsesNotifications" = "true";
    })
  ];

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Desktop client for Fluxer, an open source instant messaging and VoIP platform";
    homepage = "https://fluxer.app";
    downloadPage = "https://fluxer.app/download";
    license = lib.licenses.agpl3Plus;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames sources.platforms;
    mainProgram = pname;
  };
}

# Avatars, badges, emoji, email images and desktop spellcheck dictionaries,
# served under /web, /emoji, /avatars, /badges and /desktop.
{
  lib,
  stdenvNoCC,
  curl,
  cacert,
  fluxerRelease,
}:

let
  component = fluxerRelease.component "fluxer-static";

  # Upstream's script downloads the dictionaries from npm and checks them
  # against spellcheck-dictionaries.sha256.
  spellcheckDictionaries = stdenvNoCC.mkDerivation {
    name = "fluxer-spellcheck-dictionaries-${component.version}";
    inherit (component) src;
    nativeBuildInputs = [
      cacert
      curl
    ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      sh fluxer_static/fetch-spellcheck-dictionaries.sh $out
    '';
    dontFixup = true;
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    outputHashMode = "recursive";
    outputHash = component.hashes.spellcheckDictionaries;
    outputHashAlgo = if component.hashes.spellcheckDictionaries == "" then "sha256" else null;
  };
in
stdenvNoCC.mkDerivation {
  pname = "fluxer-static";
  inherit (component) version src;
  inherit spellcheckDictionaries;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cd fluxer_static
    cp -r LICENSE THIRD_PARTY_LICENSES.md avatars badges desktop email emoji web $out/
    mkdir -p $out/desktop/spellcheck
    cp -r ${spellcheckDictionaries} $out/desktop/spellcheck/dictionaries
    runHook postInstall
  '';

  meta = {
    description = "Static assets of a Fluxer instance";
    homepage = "https://fluxer.app";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.all;
  };
}

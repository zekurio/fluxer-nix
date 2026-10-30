{ pkgs }:

let
  fluxerRelease = pkgs.callPackage ./fluxer/release.nix { };
  callFluxer = path: args: pkgs.callPackage path ({ inherit fluxerRelease; } // args);
  rustService = callFluxer ./fluxer/rust-service.nix { };
in
{
  fluxer-desktop = pkgs.callPackage ./fluxer-desktop/package.nix { };

  fluxer-web = callFluxer ./fluxer-web/package.nix { };
  fluxer-static = callFluxer ./fluxer-static/package.nix { };
  fluxer-api = callFluxer ./fluxer-api/package.nix { };
  fluxer-gateway = callFluxer ./fluxer-gateway/package.nix { };

  fluxer-admin = rustService {
    pname = "fluxer-admin";
    component = "fluxer-admin";
    crate = "fluxer_admin";
    description = "Fluxer admin panel";
    # build.rs compiles the stylesheet with the Tailwind CLI.
    nativeBuildInputs = [ pkgs.tailwindcss_4 ];
  };

  fluxer-app-proxy = rustService {
    pname = "fluxer-app-proxy";
    component = "fluxer-app-proxy-self-hosted";
    crate = "fluxer_app_proxy";
    description = "Fluxer web app server";
  };

  fluxer-media-proxy = rustService {
    pname = "fluxer-media-proxy";
    component = "fluxer-media-proxy";
    crate = "fluxer-media-proxy";
    description = "Fluxer media proxy: uploads, thumbnails and transcoding";
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = with pkgs; [
      curl
      ffmpeg_9-headless
      lcms2
      libheif
      libwebp
      libyuv
      vips
    ];
  };

  fluxer-push = rustService {
    pname = "fluxer-push";
    component = "fluxer-push";
    crate = "fluxer-push";
    description = "Fluxer push notification service";
  };

  fluxer-gifs = rustService {
    pname = "fluxer-gifs";
    component = "fluxer-gifs";
    crate = "fluxer-gifs";
    description = "Fluxer GIF search service";
  };

  fluxer-messages = rustService {
    pname = "fluxer-messages";
    component = "fluxer-messages";
    crate = "fluxer-messages";
    features = [ "scylla" ];
    description = "Fluxer message storage service";
  };

  fluxer-snowflakes = rustService {
    pname = "fluxer-snowflakes";
    component = "fluxer-snowflakes";
    crate = "fluxer-snowflakes";
    description = "Fluxer ID allocation service";
  };

  fluxer-unfurl = rustService {
    pname = "fluxer-unfurl";
    component = "fluxer-unfurl";
    crate = "fluxer-unfurl";
    description = "Fluxer link preview service";
  };

  fluxer-users = rustService {
    pname = "fluxer-users";
    component = "fluxer-users";
    crate = "fluxer-users";
    features = [ "scylla" ];
    description = "Fluxer user service";
  };
}

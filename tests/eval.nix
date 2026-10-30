# Option logic that needs no VM: what each configuration renders, and what it
# refuses.
{
  lib,
  pkgs,
  nixosSystem,
  module,
}:

let
  eval =
    config:
    (nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        module
        config
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
        }
      ];
    }).config;

  failed = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  # The API host of an instance whose LiveKit runs elsewhere.
  apiHost = eval {
    services.fluxer = {
      domain = "chat.example.com";
      livekit = {
        url = "wss://voice.example.com";
        internalUrl = "http://10.0.0.3:7880";
        apiSecretFile = "/run/secrets/livekit";
      };
    };
  };

  remoteWithoutInternalUrl = eval {
    services.fluxer.livekit = {
      url = "wss://voice.example.com";
      apiSecretFile = "/run/secrets/livekit";
    };
  };

  # A whole instance on one host.
  instance = eval {
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
    };
  };

  # An instance with a password in its key-value URL and an SMTP password,
  # which no service but the API claims.
  withExtraSecrets = eval {
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
      secrets = {
        FLUXER_KV_URL = "/run/secrets/kv-url";
        FLUXER_EMAIL_SMTP_PASSWORD = "/run/secrets/smtp";
      };
    };
  };

  # Services that listen on a private address, for the edge on another host.
  privateAddress = eval {
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
      listenAddress = "10.0.0.2";
    };
  };

  unit = config: name: config.systemd.services."fluxer-${name}";
  env = config: name: (unit config name).environment;
  credentials =
    config: name:
    map (c: lib.head (lib.splitString ":" c)) (unit config name).serviceConfig.LoadCredential;
  servicesWith =
    config: secret:
    lib.sort lib.lessThan (
      lib.filter (name: lib.elem secret (credentials config name)) [
        "api"
        "worker"
        "gateway"
        "media-proxy"
        "push"
        "admin"
        "app-proxy"
        "gifs"
        "messages"
        "snowflakes"
        "unfurl"
        "users"
      ]
    );

  throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  results = {
    "API host has no failed assertions" = failed apiHost == [ ];
    "API host renders the LiveKit settings" =
      lib.filterAttrs (n: _: lib.hasPrefix "FLUXER_LIVEKIT_" n) apiHost.services.fluxer.environment == {
        FLUXER_LIVEKIT_ENABLED = "true";
        FLUXER_LIVEKIT_URL = "wss://voice.example.com";
        FLUXER_LIVEKIT_INTERNAL_URL = "http://10.0.0.3:7880";
        FLUXER_LIVEKIT_API_KEY = "fluxer";
        FLUXER_LIVEKIT_DEFAULT_REGION = builtins.toJSON {
          emoji = "🌍";
          id = "default";
          latitude = 0;
          longitude = 0;
          name = "Default";
        };
      };
    "API host does not run LiveKit" = !apiHost.services.livekit.enable;
    "a whole instance has no failed assertions" = failed instance == [ ];
    "a whole instance runs every service" = lib.all (n: instance.systemd.services ? "fluxer-${n}") [
      "api"
      "worker"
      "gateway"
      "media-proxy"
      "push"
      "admin"
      "app-proxy"
      "gifs"
      "messages"
      "snowflakes"
      "unfurl"
      "users"
      "seaweedfs"
      "secrets"
    ];
    "a whole instance sends LiveKit events to the local API" =
      instance.services.livekit.settings.webhook.urls == [ "http://127.0.0.1:8080/webhooks/livekit" ];
    "settings survive systemd's specifier expansion" =
      instance.systemd.services.fluxer-api.environment.FLUXER_POSTGRES_URL
      == "postgresql://fluxer@%%2Frun%%2Fpostgresql/fluxer";
    "services get secrets as files, not values" =
      let
        env = instance.systemd.services.fluxer-api.environment;
      in
      env ? FLUXER_SUDO_MODE_SECRET_FILE && !(env ? FLUXER_SUDO_MODE_SECRET);
    "the web app gets no secrets" = credentials instance "app-proxy" == [ ];
    "only the gateway gets the Erlang cookie" =
      servicesWith instance "FLUXER_ERLANG_COOKIE" == [ "gateway" ];
    "only unfurl gets the ActivityPub key" =
      servicesWith instance "FLUXER_ACTIVITYPUB_SIGNING_KEY_BASE64" == [ "unfurl" ];
    "only the API gets the setup token" = servicesWith instance "FLUXER_SETUP_TOKEN" == [ "api" ];
    "the users service gets the pseudonym secret" = lib.elem "FLUXER_PROFILE_PSEUDONYM_SECRET" (
      credentials instance "users"
    );
    "a secret replaces the setting of its name" =
      failed withExtraSecrets == [ ]
      && (env withExtraSecrets "api") ? FLUXER_KV_URL_FILE
      && !((env withExtraSecrets "api") ? FLUXER_KV_URL)
      && !((env withExtraSecrets "gateway") ? FLUXER_KV_URL);
    "a secret no service claims goes to the API and the worker" =
      servicesWith withExtraSecrets "FLUXER_EMAIL_SMTP_PASSWORD" == [
        "api"
        "worker"
      ];
    "the API and the gateway listen on the listen address" =
      (env instance "api").FLUXER_API_LISTEN_HOST == "127.0.0.1"
      && (env instance "gateway").FLUXER_GATEWAY_LISTEN_HOST == "127.0.0.1";
    "the gateway's distribution stays on loopback without epmd" =
      (env instance "gateway").ERL_DIST_PORT == "9100"
      && (env instance "gateway").FLUXER_ERLANG_DIST_INTERFACE == "{127,0,0,1}";
    "local endpoints follow the listen address" =
      (env privateAddress "push").FLUXER_INTERNAL_API_ENDPOINT == "http://10.0.0.2:8080"
      && privateAddress.services.fluxer.endpoints.gateway == "http://10.0.0.2:8081";
    "browsers get no S3 endpoint by default" =
      !((env instance "app-proxy") ? FLUXER_S3_PUBLIC_ENDPOINT);
    "the local database collects statement statistics" =
      instance.services.postgresql.settings.shared_preload_libraries == "pg_stat_statements";
    "a remote LiveKit needs internalUrl" = lib.any (lib.hasInfix "internalUrl") (
      failed remoteWithoutInternalUrl
    );
    "a secret in the store is rejected" =
      throws
        (eval {
          services.fluxer.secrets.FLUXER_SUDO_MODE_SECRET = ./eval.nix;
        }).services.fluxer.secrets;
    "a secret under a non-variable name is rejected" =
      failed (eval {
        services.fluxer.secrets."sudo mode" = "/run/secrets/sudo";
      }) != [ ];
  };

  failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) results);
in
pkgs.runCommand "fluxer-module-eval" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      echo "failed: ${lib.concatStringsSep ", " failures}" >&2
      exit 1
    ''
)

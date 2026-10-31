# The Fluxer services. Each one is a systemd unit that can be turned on by
# itself, so the parts of an instance can be spread over several hosts.
{
  config,
  lib,
  pkgs,
  fluxerPackages,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkIf
    mkOption
    types
    ;

  cfg = config.services.fluxer;
  local = name: cfg.${name}.enable;
  url = name: "http://${cfg.localAddress}:${toString cfg.${name}.port}";

  rustEnv = {
    TOKIO_WORKER_THREADS = 2;
    MALLOC_ARENA_MAX = 2;
  };
  nodeEnv = {
    NODE_ENV = "production";
    NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
  };

  fluxer = map (name: "FLUXER_${name}");

  # The shared secrets each service reads, from upstream's configuration
  # loaders. Recheck them when the release changes.
  apiSecrets = fluxer [
    "ADMIN_OAUTH_CLIENT_SECRET"
    # Only checked to be present.
    "ADMIN_SECRET_KEY_BASE"
    "CASSANDRA_PASSWORD"
    "CONNECTION_INITIATION_SECRET"
    "GATEWAY_RPC_AUTH_TOKEN"
    "KLIPY_API_KEY"
    "KV_URL"
    "LIVEKIT_API_SECRET"
    "MEDIA_PROXY_ATTACHMENT_URL_SECRETS_BASE64"
    "MEDIA_PROXY_SECRET_KEY"
    "MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64"
    "NATS_AUTH_TOKEN"
    "POSTGRES_PASSWORD"
    "POSTGRES_URL"
    "PROFILE_PSEUDONYM_SECRET"
    "S3_SECRET_ACCESS_KEY"
    "SEARCH_API_KEY"
    "SUDO_MODE_SECRET"
    "VAPID_PRIVATE_KEY"
    "VAPID_PUBLIC_KEY"
    "YOUTUBE_API_KEY"
  ];
  databaseSecrets = fluxer [
    "CASSANDRA_PASSWORD"
    "POSTGRES_PASSWORD"
    "POSTGRES_URL"
  ];

  svcSettings = name: port: {
    FLUXER_SVC_NAME = name;
    # Router and shard in one process. Upstream's Helm chart can split them.
    FLUXER_SVC_MODE = "combined";
    FLUXER_SVC_SHARD_COUNT = 1;
    FLUXER_SVC_PORT = port;
    FLUXER_SVC_LISTEN_HOST = cfg.listenAddress;
  };

  svc =
    name: description:
    {
      settings ? { },
      secrets ? [ ],
      database ? false,
    }:
    {
      inherit description;
      package = "fluxer-${name}";
      exe = "fluxer-${name}";
      port =
        {
          gifs = 8091;
          messages = 8092;
          snowflakes = 8093;
          unfurl = 8094;
          users = 8095;
        }
        .${name};
      settings = port: rustEnv // svcSettings name port // settings;
      secrets = fluxer ([ "NATS_AUTH_TOKEN" ] ++ secrets) ++ lib.optionals database databaseSecrets;
      after = [ "nats" ] ++ lib.optional database "postgres";
    };

  # The services, with upstream's settings from its compose file. Ports are
  # moved apart, since they all listen on 8080 in their containers. Secrets
  # no service claims, such as SMTP or Stripe keys, go to the services with
  # unclaimedSecrets: the API and the worker read most of the configuration.
  components = {
    api = {
      description = "Fluxer API";
      package = "fluxer-api";
      exe = "fluxer-api";
      port = 8080;
      settings =
        port:
        nodeEnv
        // {
          FLUXER_API_PORT = port;
          FLUXER_API_LISTEN_HOST = cfg.listenAddress;
          FLUXER_POSTGRES_MAX_CONNECTIONS = 25;
          FLUXER_API_PRESIGNED_ATTACHMENT_UPLOADS_ENABLED = true;
          FLUXER_API_EMBEDDED_WORKER = false;
          NODE_OPTIONS = "--max-old-space-size-percentage=60";
        };
      secrets = apiSecrets ++ fluxer [ "SETUP_TOKEN" ];
      unclaimedSecrets = true;
      serviceConfig = {
        # The operator socket, /run/fluxer/operator.sock, is fixed.
        RuntimeDirectory = "fluxer";
        RuntimeDirectoryMode = "0700";
        # Started means serving: the API listens once its startup is done, so
        # the services ordered after it do not find it missing.
        ExecStartPost = pkgs.writeShellScript "fluxer-api-ready" ''
          until ${lib.getExe pkgs.curl} -fs --max-time 2 -o /dev/null \
            http://${cfg.localAddress}:${toString cfg.api.port}/_health; do
            sleep 1
          done
        '';
        TimeoutStartSec = 300;
      };
      after = [
        "postgres"
        "valkey"
        "nats"
        "search"
        "s3"
        "gifs"
        "snowflakes"
        "messages"
        "users"
      ];
      voice = true;
    };

    worker = {
      description = "Fluxer background worker";
      package = "fluxer-api";
      exe = "fluxer-worker";
      port = null;
      settings =
        _:
        nodeEnv
        // {
          FLUXER_API_WORKER_MODE = "all_lanes";
          # For its metrics server, which only runs if given a port.
          FLUXER_API_LISTEN_HOST = cfg.listenAddress;
          # Runs the cron scheduler, so only one worker per instance.
          FLUXER_API_WORKER_ENABLE_CRON_SCHEDULER = true;
          FLUXER_POSTGRES_MAX_CONNECTIONS = 25;
          NODE_OPTIONS = "--max-old-space-size-percentage=55";
        };
      secrets = apiSecrets;
      unclaimedSecrets = true;
      after = [
        "postgres"
        "valkey"
        "nats"
        "s3"
        "snowflakes"
        "messages"
        "users"
      ];
      voice = true;
    };

    gateway = {
      description = "Fluxer gateway";
      package = "fluxer-gateway";
      exe = "fluxer-gateway";
      port = 8081;
      settings = port: {
        FLUXER_GATEWAY_PORT = port;
        FLUXER_GATEWAY_LISTEN_HOST = cfg.listenAddress;
        FLUXER_ERLANG_NODE_NAME = "fluxer_gateway@127.0.0.1";
        FLUXER_ERLANG_DIST_PORT = cfg.gateway.distributionPort;
        # Distribution on loopback, at a fixed port the release tells the node
        # about, so no epmd starts. services.fluxer.gateway.cluster moves it to
        # an address other gateways reach.
        FLUXER_ERLANG_DIST_INTERFACE = "{127,0,0,1}";
        ERL_DIST_PORT = cfg.gateway.distributionPort;
        # Where the release writes its generated vm.args and sys.config, and
        # the entrypoint the cookie, as .erlang.cookie.
        RELX_OUT_FILE_PATH = "/run/fluxer-gateway";
        HOME = "/run/fluxer-gateway";
      };
      secrets = fluxer [
        "ERLANG_COOKIE"
        "GATEWAY_RPC_AUTH_TOKEN"
        "NATS_AUTH_TOKEN"
      ];
      serviceConfig = {
        RuntimeDirectory = "fluxer-gateway";
        RuntimeDirectoryMode = "0700";
        LimitNOFILE = 65536;
      };
      # It fetches its configuration from the API once it starts.
      after = [
        "nats"
        "valkey"
        "api"
      ];
    };

    mediaProxy = {
      description = "Fluxer media proxy";
      package = "fluxer-media-proxy";
      exe = "fluxer-media-proxy";
      port = 8083;
      settings = port: {
        FLUXER_MEDIA_PROXY_HOST = cfg.listenAddress;
        FLUXER_MEDIA_PROXY_PORT = port;
        FLUXER_MEDIA_PROXY_MODE = "upload";
        FLUXER_MEDIA_PROXY_STORAGE_BACKEND = "s3";
        FLUXER_S3_READ_SIGNED = true;
        FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SPOOL_MAX_TOTAL_BYTES = 2147483648;
        TOKIO_WORKER_THREADS = 4;
        VIPS_CONCURRENCY = 1;
        VIPS_DISC_THRESHOLD = "1g";
      };
      secrets = fluxer [
        "MEDIA_PROXY_ATTACHMENT_URL_SECRETS_BASE64"
        "MEDIA_PROXY_SECRET_KEY"
        "MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64"
        "S3_SECRET_ACCESS_KEY"
        "S3_SESSION_TOKEN"
      ];
      after = [
        "nats"
        "s3"
      ];
    };

    push = {
      description = "Fluxer push notifications";
      package = "fluxer-push";
      exe = "fluxer-push";
      port = 8126;
      settings =
        port:
        rustEnv
        // {
          FLUXER_PUSH_SERVICE_HOST = cfg.listenAddress;
          FLUXER_PUSH_SERVICE_PORT = port;
        };
      secrets = fluxer [
        "GATEWAY_RPC_AUTH_TOKEN"
        "NATS_AUTH_TOKEN"
        "PUSH_APNS_PRIVATE_KEY"
        "PUSH_FCM_PRIVATE_KEY"
        "VAPID_PRIVATE_KEY"
        "VAPID_PUBLIC_KEY"
      ];
      after = [
        "nats"
        "api"
      ];
    };

    admin = {
      description = "Fluxer admin panel";
      package = "fluxer-admin";
      exe = "fluxer_admin";
      port = 8084;
      settings =
        port:
        rustEnv
        // {
          FLUXER_ADMIN_HOST = cfg.listenAddress;
          FLUXER_ADMIN_PORT = port;
          FLUXER_ADMIN_BASE_PATH = cfg.admin.basePath;
          FLUXER_API_ENDPOINT = cfg.endpoints.api;
          FLUXER_STATIC_CDN_ENDPOINT = cfg.publicOrigin;
        };
      secrets = fluxer [
        "ADMIN_OAUTH_CLIENT_SECRET"
        "ADMIN_SECRET_KEY_BASE"
      ];
      after = [ "api" ];
    };

    appProxy = {
      description = "Fluxer web app";
      package = "fluxer-app-proxy";
      exe = "fluxer_app_proxy";
      port = 8085;
      settings = port: {
        FLUXER_APP_PROXY_HOST = cfg.listenAddress;
        FLUXER_APP_PROXY_PORT = port;
        FLUXER_STATIC_DIR = "${cfg.appProxy.webPackage}";
        DISCOVERY_UPSTREAM_URL = "${cfg.endpoints.api}/.well-known/fluxer";
        DISCOVERY_REFRESH_INTERVAL_MS = 5000;
        TOKIO_WORKER_THREADS = 2;
      };
      secrets = [ ];
      after = [ "api" ];
    };

    gifs = svc "gifs" "Fluxer GIF search" {
      settings.FLUXER_GIFS_SHARD_CACHE_MAX_BYTES = 134217728;
      secrets = [ "MEDIA_PROXY_SECRET_KEY" ];
    };
    messages = svc "messages" "Fluxer message storage" {
      settings.FLUXER_POSTGRES_MAX_CONNECTIONS = 20;
      database = true;
    };
    snowflakes = svc "snowflakes" "Fluxer ID allocation" { };
    unfurl = svc "unfurl" "Fluxer link previews" {
      settings.FLUXER_MEDIA_PROXY_ENDPOINT = cfg.endpoints.mediaProxy;
      secrets = [
        "ACTIVITYPUB_SIGNING_KEY_BASE64"
        "KLIPY_API_KEY"
        "MEDIA_PROXY_SECRET_KEY"
        "YOUTUBE_API_KEY"
      ];
    };
    users = svc "users" "Fluxer user service" {
      settings.FLUXER_POSTGRES_MAX_CONNECTIONS = 20;
      secrets = [ "PROFILE_PSEUDONYM_SECRET" ];
      database = true;
    };
  };

  # The units a dependency stands for, when it runs on this host.
  dependencyUnits = {
    postgres = lib.optionals cfg.postgres.createLocally [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    valkey = lib.optional cfg.valkey.createLocally "redis-fluxer.service";
    nats = lib.optional cfg.nats.createLocally "nats.service";
    search = lib.optional cfg.search.createLocally "meilisearch.service";
    s3 = lib.optional cfg.s3.seaweedfs.enable "fluxer-seaweedfs-init.service";
  };
  unitName = name: "fluxer-${lib.toLower (lib.replaceStrings [ "P" ] [ "-p" ] name)}";

  # A dependency is a backing service or another Fluxer service. Only those
  # on this host order the start.
  unitsFor =
    dep: dependencyUnits.${dep} or (lib.optional cfg.${dep}.enable "${unitName dep}.service");

  componentOptions =
    name: c:
    {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        defaultText = literalExpression "config.services.fluxer.enable";
        description = "Run the ${c.description} on this host.";
      };
      package = mkOption {
        type = types.package;
        default = fluxerPackages.${c.package};
        defaultText = literalExpression "fluxer-nix.packages.\${system}.${c.package}";
        description = "The package of the ${c.description}.";
      };
      settings = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.str
            types.int
            types.bool
          ]
        );
        default = { };
        description = "Settings for this service only, over services.fluxer.settings.";
      };
      secrets = mkOption {
        type = types.attrsOf types.externalPath;
        default = { };
        description = "Secret files for this service only, over services.fluxer.secrets.";
      };
    }
    // lib.optionalAttrs (c.port != null) {
      port = mkOption {
        type = types.port;
        default = c.port;
        description = "Port of the ${c.description}.";
      };
    };

  claimedSecrets = lib.unique (lib.concatMap (c: c.secrets) (lib.attrValues components));
  # Only given ones: a generated secret no service claims is for a backing
  # service, such as the Valkey password.
  unclaimedSecrets = lib.filter (n: !lib.elem n claimedSecrets) (lib.attrNames cfg.secrets);

  voiceSecret = lib.optionalAttrs (cfg.livekit.url != null && cfg.livekit.apiSecretFile != null) {
    FLUXER_LIVEKIT_API_SECRET = cfg.livekit.apiSecretFile;
  };

  mkUnit =
    name: c:
    let
      ccfg = cfg.${name};
      env = cfg.serviceEnv {
        settings = c.settings (ccfg.port or null) // ccfg.settings;
        secrets = lib.optionalAttrs (c.voice or false) voiceSecret // ccfg.secrets;
        secretNames = c.secrets ++ lib.optionals (c.unclaimedSecrets or false) unclaimedSecrets;
      };
      deps =
        lib.concatMap unitsFor (c.after or [ ])
        ++ lib.optional cfg.generateSecrets "fluxer-secrets.service";
    in
    lib.nameValuePair (unitName name) (
      mkIf ccfg.enable {
        description = c.description;
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ] ++ deps;
        wants = [ "network-online.target" ] ++ deps;
        inherit (env) environment;
        serviceConfig = {
          ExecStart = lib.getExe' ccfg.package c.exe;
          inherit (env.serviceConfig) LoadCredential;
          User = cfg.user;
          Group = cfg.group;
          Slice = "system-fluxer.slice";
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = 35;

          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
          UMask = "0077";
        }
        // c.serviceConfig or { };
      }
    );
in
{
  options.services.fluxer = lib.mapAttrs componentOptions components // {
    gateway = componentOptions "gateway" components.gateway // {
      distributionPort = mkOption {
        type = types.port;
        default = 9100;
        description = "Erlang distribution port of the gateway.";
      };
    };

    admin = componentOptions "admin" components.admin // {
      basePath = mkOption {
        type = types.str;
        default = "/admin";
        description = "The path the admin panel is served under.";
      };
    };

    appProxy = componentOptions "appProxy" components.appProxy // {
      webPackage = mkOption {
        type = types.package;
        default = fluxerPackages.fluxer-web;
        defaultText = literalExpression "fluxer-nix.packages.\${system}.fluxer-web";
        description = "The web app the app proxy serves.";
      };
    };

    endpoints = {
      api = mkOption {
        type = types.str;
        default = url "api";
        defaultText = lib.literalMD "`services.fluxer.api.port` on `services.fluxer.listenAddress`, or on loopback for a wildcard address";
        description = "Where the other services reach the API.";
      };
      mediaProxy = mkOption {
        type = types.str;
        default = url "mediaProxy";
        defaultText = lib.literalMD "`services.fluxer.mediaProxy.port` on `services.fluxer.listenAddress`, or on loopback for a wildcard address";
        description = "Where the other services reach the media proxy.";
      };
    };
  };

  config = lib.mkMerge [
    {
      services.fluxer.settings = lib.mapAttrs (_: lib.mkDefault) (
        {
          FLUXER_INTERNAL_API_ENDPOINT = cfg.endpoints.api;
          FLUXER_INTERNAL_MEDIA_PROXY_ENDPOINT = cfg.endpoints.mediaProxy;
        }
        // lib.optionalAttrs (cfg.publicOrigin != null) {
          FLUXER_ADMIN_ENDPOINT = "${cfg.publicOrigin}${cfg.admin.basePath}";
        }
      );

      systemd.services = lib.mapAttrs' mkUnit components;
    }

    (mkIf (lib.any local (lib.attrNames components)) {
      # As in nixpkgs' modules: a user or group under another name is the
      # operator's, and may be a normal user or come from a directory.
      users.users = mkIf (cfg.user == "fluxer") {
        fluxer = {
          isSystemUser = true;
          inherit (cfg) group;
          description = "Fluxer services";
        };
      };
      users.groups = mkIf (cfg.group == "fluxer") { fluxer = { }; };

      systemd.slices.system-fluxer = {
        description = "Fluxer chat instance";
        documentation = [ "https://docs.fluxer.app/operator/" ];
      };

      # Peer authentication maps the services' user to the role of that name.
      assertions = [
        {
          assertion =
            cfg.postgres.createLocally
            && lib.any (n: local n && lib.elem "postgres" (components.${n}.after or [ ])) (
              lib.attrNames components
            )
            -> cfg.postgres.user == cfg.user;
          message = "The services sign in to the local database over its socket as their own user, so services.fluxer.postgres.user has to be services.fluxer.user.";
        }
      ];
    })

  ];
}

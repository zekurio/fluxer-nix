# The backing services: Postgres, Valkey, NATS, Meilisearch and S3. Each one
# is either set up on this host or reached at an address you give.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.services.fluxer;
  mapDefaults = lib.mapAttrs (_: lib.mkDefault);

  createLocally =
    what:
    mkOption {
      type = types.bool;
      default = cfg.enable;
      defaultText = literalExpression "config.services.fluxer.enable";
      description = "Run ${what} on this host for Fluxer.";
    };

  s3 = cfg.s3;
  seaweed = s3.seaweedfs;
  weed = lib.getExe' seaweed.package "weed";

  searchKey = cfg.secretFiles.FLUXER_SEARCH_API_KEY or null;
  s3Secret = cfg.secretFiles.FLUXER_S3_SECRET_ACCESS_KEY or null;
in
{
  options.services.fluxer = {
    postgres = {
      createLocally = createLocally "PostgreSQL";
      host = mkOption {
        type = types.str;
        default = "/run/postgresql";
        description = "Host name or Unix socket directory of the PostgreSQL server.";
      };
      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };
      database = mkOption {
        type = types.str;
        default = "fluxer";
        description = "Database name. Fluxer creates its tables on startup.";
      };
      user = mkOption {
        type = types.str;
        default = cfg.user;
        defaultText = literalExpression "config.services.fluxer.user";
        description = ''
          Database role. It must own the database. For a server elsewhere, put
          its password in services.fluxer.secrets.FLUXER_POSTGRES_PASSWORD.
        '';
      };
      statementStats = mkOption {
        type = types.bool;
        default = cfg.postgres.createLocally;
        defaultText = literalExpression "createLocally";
        description = ''
          Collect query statistics with pg_stat_statements in the local server,
          as upstream's image does. Fluxer itself does not read them. This
          preloads the library for the whole server, which restarts it once.
        '';
      };
    };

    valkey = {
      createLocally = createLocally "Valkey";
      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Port of the local Valkey server.";
      };
      url = mkOption {
        type = types.str;
        default = "redis://127.0.0.1:${toString cfg.valkey.port}/0";
        defaultText = literalExpression ''"redis://127.0.0.1:''${toString port}/0"'';
        description = "URL of the key-value store. Put a URL with a password in services.fluxer.secrets.FLUXER_KV_URL instead.";
      };
    };

    nats = {
      createLocally = createLocally "NATS with JetStream";
      port = mkOption {
        type = types.port;
        default = 4222;
        description = "Port of the local NATS server.";
      };
      url = mkOption {
        type = types.str;
        default = "nats://127.0.0.1:${toString cfg.nats.port}";
        defaultText = literalExpression ''"nats://127.0.0.1:''${toString port}"'';
        description = "URL of the NATS server. Its token, if any, goes in services.fluxer.secrets.FLUXER_NATS_AUTH_TOKEN.";
      };
    };

    search = {
      createLocally = createLocally "Meilisearch";
      port = mkOption {
        type = types.port;
        default = 7700;
        description = "Port of the local Meilisearch server.";
      };
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:${toString cfg.search.port}";
        defaultText = literalExpression ''"http://127.0.0.1:''${toString port}"'';
        description = ''
          URL of the Meilisearch server. Its master key, at least 16 bytes, goes
          in services.fluxer.secrets.FLUXER_SEARCH_API_KEY.
        '';
      };
    };

    s3 = {
      endpoint = mkOption {
        type = types.str;
        default = "http://127.0.0.1:${toString seaweed.port}";
        defaultText = literalExpression ''"http://127.0.0.1:''${toString s3.seaweedfs.port}"'';
        description = "The S3 endpoint the services use.";
      };
      publicEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://s3.example.com";
        description = ''
          The S3 endpoint browsers can reach, for presigned links and the web
          app's content security policy. Leave it null, as upstream's compose
          file does, when browsers get files only through the media proxy; the
          API then signs links for the internal endpoint. Give a host name: the
          web app derives a virtual-host origin from it, which fails for an IP
          address.
        '';
      };
      region = mkOption {
        type = types.str;
        default = "us-east-1";
        description = "S3 region.";
      };
      forcePathStyle = mkOption {
        type = types.bool;
        default = true;
        description = "Address buckets as a path rather than a subdomain.";
      };
      accessKeyId = mkOption {
        type = types.str;
        default = "fluxer";
        description = ''
          S3 access key id. The secret key goes in
          services.fluxer.secrets.FLUXER_S3_SECRET_ACCESS_KEY, letters and digits
          only for the local store.
        '';
      };
      buckets = lib.genAttrs [ "cdn" "uploads" "reports" "harvests" ] (
        name:
        mkOption {
          type = types.str;
          default = if name == "cdn" then "fluxer" else "fluxer-${name}";
          description = "Name of the ${name} bucket. It has to exist.";
        }
      );

      seaweedfs = {
        enable = mkOption {
          type = types.bool;
          default = cfg.enable;
          defaultText = literalExpression "config.services.fluxer.enable";
          description = "Run SeaweedFS on this host as the S3 store, and create the buckets.";
        };
        package = lib.mkPackageOption pkgs "seaweedfs" { };
        port = mkOption {
          type = types.port;
          default = 8333;
          description = "Port of the S3 API.";
        };
        masterPort = mkOption {
          type = types.port;
          default = 9333;
          description = "Port of the SeaweedFS master.";
        };
        uploadsTtl = mkOption {
          type = types.str;
          default = "1d";
          description = ''
            How long a file stays in the uploads bucket. A file moves out when
            its message is sent, so this removes uploads nobody sent. "off"
            keeps them.
          '';
        };
        volumeSizeLimitMB = mkOption {
          type = types.int;
          default = 1024;
          description = "Size in MB at which SeaweedFS opens another volume.";
        };
      };
    };
  };

  config = mkMerge [
    {
      services.fluxer.generate = {
        FLUXER_SEARCH_API_KEY = "hex32";
        FLUXER_S3_SECRET_ACCESS_KEY = "hex32";
      };

      services.fluxer.settings = mapDefaults (
        {
          FLUXER_DATABASE_BACKEND = "postgres";
          FLUXER_POSTGRES_HOST = cfg.postgres.host;
          FLUXER_POSTGRES_PORT = cfg.postgres.port;
          FLUXER_POSTGRES_DATABASE = cfg.postgres.database;
          FLUXER_POSTGRES_USERNAME = cfg.postgres.user;
          FLUXER_KV_URL = cfg.valkey.url;
          FLUXER_NATS_URL = cfg.nats.url;
          FLUXER_NATS_JETSTREAM_URL = cfg.nats.url;
          FLUXER_SVC_NATS_URL = cfg.nats.url;
          FLUXER_SEARCH_ENGINE = "meilisearch";
          FLUXER_SEARCH_URL = cfg.search.url;
          FLUXER_S3_ENDPOINT = s3.endpoint;
          FLUXER_S3_REGION = s3.region;
          FLUXER_S3_FORCE_PATH_STYLE = s3.forcePathStyle;
          FLUXER_S3_ACCESS_KEY_ID = s3.accessKeyId;
          FLUXER_S3_BUCKET_CDN = s3.buckets.cdn;
          FLUXER_S3_BUCKET_UPLOADS = s3.buckets.uploads;
          FLUXER_S3_BUCKET_REPORTS = s3.buckets.reports;
          FLUXER_S3_BUCKET_HARVESTS = s3.buckets.harvests;
        }
        // lib.optionalAttrs (s3.publicEndpoint != null) {
          FLUXER_S3_PUBLIC_ENDPOINT = s3.publicEndpoint;
        }
        // lib.optionalAttrs cfg.postgres.createLocally {
          FLUXER_POSTGRES_SSL = false;
          # Peer authentication over the socket. The API refuses a production
          # configuration without a password unless it is given a URL.
          FLUXER_POSTGRES_URL = "postgresql://${cfg.postgres.user}@${lib.escapeURL cfg.postgres.host}/${cfg.postgres.database}";
        }
      );

    }

    (mkIf cfg.postgres.createLocally {
      services.postgresql = {
        enable = true;
        ensureDatabases = [ cfg.postgres.database ];
        ensureUsers = [
          {
            name = cfg.postgres.user;
            ensureDBOwnership = true;
          }
        ];
      };
      assertions = [
        {
          assertion = cfg.postgres.database == cfg.postgres.user;
          message = "The local database has to be named after its role, services.fluxer.postgres.user.";
        }
      ];

      # The API checks on startup whether pg_stat_statements is preloaded,
      # which takes reading the server's settings, and installs it if so,
      # which takes a superuser. Without the grant it logs a warning.
      services.postgresql.settings.shared_preload_libraries = lib.mkIf cfg.postgres.statementStats [
        "pg_stat_statements"
      ];
      systemd.services.postgresql-setup.postStart = ''
        psql -tAc 'GRANT pg_read_all_settings TO "${cfg.postgres.user}"'
      ''
      + lib.optionalString cfg.postgres.statementStats ''
        psql -d ${lib.escapeShellArg cfg.postgres.database} -tAc 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
      '';
    })

    (mkIf cfg.valkey.createLocally {
      # nixpkgs' Redis module picks one package for every server it runs.
      services.redis.package = lib.mkDefault pkgs.valkey;
      services.redis.servers.fluxer = {
        enable = true;
        bind = "127.0.0.1";
        inherit (cfg.valkey) port;
        appendOnly = true;
        save = [ ];
        settings = {
          appendfsync = "everysec";
          maxmemory = "192mb";
          maxmemory-policy = "noeviction";
        };
      };
    })

    (mkIf cfg.nats.createLocally {
      services.nats = {
        enable = true;
        jetstream = true;
        inherit (cfg.nats) port;
        serverName = "fluxer";
        settings = {
          host = "127.0.0.1";
          http_port = 8222;
          jetstream = {
            max_memory_store = 64 * 1024 * 1024;
            max_file_store = 10 * 1024 * 1024 * 1024;
          };
        };
      };
    })

    (mkIf cfg.search.createLocally {
      assertions = [
        {
          assertion = searchKey != null;
          message = "The local Meilisearch needs services.fluxer.secrets.FLUXER_SEARCH_API_KEY, or services.fluxer.generateSecrets.";
        }
      ];
      services.meilisearch = {
        enable = true;
        listenAddress = "127.0.0.1";
        listenPort = cfg.search.port;
        masterKeyFile = searchKey;
        settings = {
          env = "production";
          max_indexing_memory = "256 MiB";
          max_indexing_threads = 2;
          log_level = "WARN";
        };
      };
      systemd.services.meilisearch = lib.mkIf cfg.generateSecrets {
        after = [ "fluxer-secrets.service" ];
        wants = [ "fluxer-secrets.service" ];
      };
    })

    (mkIf seaweed.enable {
      assertions = [
        {
          assertion = s3Secret != null;
          message = "The local SeaweedFS needs services.fluxer.secrets.FLUXER_S3_SECRET_ACCESS_KEY, or services.fluxer.generateSecrets.";
        }
      ];

      systemd.services.fluxer-seaweedfs = {
        description = "SeaweedFS object store for Fluxer";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment.WEED_MASTER_VOLUME_GROWTH_COPY_1 = "1";
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            weed
            "server"
            "-s3"
            "-s3.port=${toString seaweed.port}"
            "-s3.iam=false"
            "-ip=127.0.0.1"
            "-ip.bind=127.0.0.1"
            "-master.port=${toString seaweed.masterPort}"
            # The volume server defaults to 8080, the API's port.
            "-volume.port=8380"
            "-filer.port=8888"
            "-dir=/var/lib/fluxer-seaweedfs"
            "-master.telemetry=false"
            "-master.volumeSizeLimitMB=${toString seaweed.volumeSizeLimitMB}"
            "-master.garbageThreshold=0.1"
            "-volume.max=10000"
          ];
          DynamicUser = true;
          StateDirectory = "fluxer-seaweedfs";
          WorkingDirectory = "/var/lib/fluxer-seaweedfs";
          Restart = "on-failure";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
        };
      };

      # Upstream's seaweedfs-init: create the buckets, the S3 identity and the
      # expiry of the uploads bucket.
      systemd.services.fluxer-seaweedfs-init = {
        description = "Create the Fluxer buckets";
        wantedBy = [ "multi-user.target" ];
        after = [
          "fluxer-seaweedfs.service"
        ]
        ++ lib.optional cfg.generateSecrets "fluxer-secrets.service";
        requires = [ "fluxer-seaweedfs.service" ];
        path = [
          pkgs.coreutils
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          DynamicUser = true;
          LoadCredential = [ "secret:${s3Secret}" ];
        };
        script = ''
          master=127.0.0.1:${toString seaweed.masterPort}
          shell() { timeout 10 ${weed} shell -master="$master" 2>&1; }
          buckets=${lib.escapeShellArg (lib.concatStringsSep " " (lib.attrValues s3.buckets))}
          secret=$(cat "$CREDENTIALS_DIRECTORY/secret")
          ${
            if seaweed.uploadsTtl == "off" then
              ''ttl_rule="fs.configure -locationPrefix=/buckets/${s3.buckets.uploads}/ -delete -apply"''
            else
              ''ttl_rule="fs.configure -locationPrefix=/buckets/${s3.buckets.uploads}/ -ttl=${seaweed.uploadsTtl} -apply"''
          }
          for attempt in $(seq 1 60); do
            listed=$(echo "s3.bucket.list" | shell) || { sleep 2; continue; }
            missing=""
            for b in $buckets; do
              echo "$listed" | grep -q "^[[:space:]]*$b[[:space:]]" || missing="$missing $b"
            done
            if [ -z "$missing" ]; then
              echo "s3.configure -user=fluxer -access_key=${s3.accessKeyId} -secret_key=$secret -actions=Admin,Read,Write,List,Tagging -apply" | shell >/dev/null
              echo "$ttl_rule" | shell >/dev/null
              echo "buckets ready"
              exit 0
            fi
            for b in $missing; do
              echo "s3.bucket.create -name $b" | shell >/dev/null
            done
            sleep 2
          done
          echo "could not create the buckets:$missing" >&2
          exit 1
        '';
      };
    })
  ];
}

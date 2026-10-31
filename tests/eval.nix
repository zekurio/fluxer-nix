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

  # A whole instance under the operator's own user and group.
  ownUser = eval {
    users.users.chat = {
      isNormalUser = true;
      group = "users";
    };
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
      user = "chat";
      group = "users";
      postgres.database = "chat";
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

  # One gateway of a cluster of two, with the edge in front of both.
  clusterNode =
    extra:
    eval {
      imports = [ extra ];
      services.fluxer = {
        enable = true;
        domain = "chat.example.com";
        secrets.FLUXER_ERLANG_COOKIE = "/run/secrets/erlang-cookie";
        gateway.cluster = {
          enable = true;
          address = "10.0.0.2";
          peers = [
            "10.0.0.2"
            "10.0.0.3"
          ];
          openFirewall = true;
        };
        endpoints.gateway = [
          "http://10.0.0.2:8081"
          "http://10.0.0.3:8081"
        ];
      };
    };
  gatewayNode = clusterNode { };

  # The host with the backing services, shared with one other host.
  sharedBacking = eval {
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
      backingServices = {
        listenAddress = "10.0.0.1";
        clients = [ "10.0.0.2" ];
      };
    };
  };

  # A host that runs only the worker, against the shared backing services.
  remoteWorker = eval {
    services.fluxer = {
      domain = "chat.example.com";
      worker.enable = true;
      postgres.host = "10.0.0.1";
      valkey = {
        url = "redis://10.0.0.1:6379/0";
        passwordFile = "/run/secrets/valkey";
      };
      nats.url = "nats://10.0.0.1:4222";
    };
  };

  # Two hosts on the module's WireGuard tunnel. main shares its backing
  # services with worker; worker cannot be reached from outside.
  tunnelHost =
    name: extra:
    eval {
      imports = [ extra ];
      networking.hostName = name;
      services.fluxer = {
        domain = "chat.example.com";
        tunnel.wireguard = {
          enable = true;
          hosts = {
            main = {
              address = "10.77.0.1";
              publicKey = "main-key";
              endpoint = "main.example.com:51820";
            };
            worker = {
              address = "10.77.0.2";
              publicKey = "worker-key";
            };
          };
          privateKeyFile = "/run/secrets/wireguard";
        };
      };
    };
  tunnelMain = tunnelHost "main" {
    services.fluxer = {
      enable = true;
      backingServices.clients = [ "10.77.0.2" ];
      secrets.FLUXER_ERLANG_COOKIE = "/run/secrets/erlang-cookie";
      gateway.cluster = {
        enable = true;
        peers = [
          "10.77.0.1"
          "10.77.0.2"
        ];
        openFirewall = true;
      };
    };
  };
  tunnelWorker = tunnelHost "worker" { services.fluxer.worker.enable = true; };

  # The host with the backing services on a tunnel set up elsewhere.
  tailscaleMain = eval {
    networking.nftables.enable = true;
    services.fluxer = {
      enable = true;
      domain = "chat.example.com";
      tunnel = {
        address = "100.64.0.1";
        interface = "tailscale0";
      };
      backingServices.clients = [ "100.64.0.2" ];
    };
  };
  nonlocalBind = config: config.boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" or null;

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
      && privateAddress.services.fluxer.endpoints.gateway == [ "http://10.0.0.2:8081" ];
    "browsers get no S3 endpoint by default" =
      !((env instance "app-proxy") ? FLUXER_S3_PUBLIC_ENDPOINT);
    "the local database collects statement statistics" =
      instance.services.postgresql.settings.shared_preload_libraries == "pg_stat_statements";
    "a gateway cluster node has no failed assertions" = failed gatewayNode == [ ];
    "a gateway cluster node is named and listens on its address" =
      lib.filterAttrs (
        n: _:
        lib.elem n [
          "FLUXER_ERLANG_NODE_NAME"
          "FLUXER_ERLANG_DIST_INTERFACE"
          "FLUXER_GATEWAY_CLUSTER_ENABLED"
          "FLUXER_GATEWAY_CLUSTER_STATIC_PEERS"
        ]
      ) (env gatewayNode "gateway") == {
        FLUXER_ERLANG_NODE_NAME = "fluxer_gateway@10.0.0.2";
        FLUXER_ERLANG_DIST_INTERFACE = "{10,0,0,2}";
        FLUXER_GATEWAY_CLUSTER_ENABLED = "true";
        FLUXER_GATEWAY_CLUSTER_STATIC_PEERS = "fluxer_gateway@10.0.0.2,fluxer_gateway@10.0.0.3";
      };
    "a gateway cluster opens the distribution port to its peers only" =
      lib.hasInfix ''
        iptables -A nixos-fw -p tcp -s 10.0.0.2 --dport 9100 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s 10.0.0.3 --dport 9100 -j nixos-fw-accept
      '' gatewayNode.networking.firewall.extraCommands
      &&
        lib.hasInfix "ip saddr { 10.0.0.2, 10.0.0.3 } tcp dport { 9100 } accept"
          (clusterNode {
            networking.nftables.enable = true;
          }).networking.firewall.extraInputRules;
    "a gateway cluster needs a shared cookie" = lib.any (lib.hasInfix "same Erlang cookie") (
      failed (clusterNode {
        services.fluxer.secrets = lib.mkForce { };
      })
    );
    "the edge spreads gateway connections over every gateway" =
      lib.hasInfix "import fluxer_upstream http://10.0.0.2:8081 http://10.0.0.3:8081"
        gatewayNode.services.caddy.virtualHosts."chat.example.com".extraConfig;
    "NATS requires a token" =
      lib.hasInfix "/run/fluxer-nats/nats.conf" instance.systemd.services.nats.serviceConfig.ExecStart
      &&
        instance.systemd.services.nats.serviceConfig.LoadCredential == [
          "token:/var/lib/fluxer-secrets/FLUXER_NATS_AUTH_TOKEN"
        ];
    "Valkey requires a password, which the services get in their URL" =
      instance.services.redis.servers.fluxer.requirePassFile
      == "/var/lib/fluxer-secrets/FLUXER_KV_PASSWORD"
      && lib.elem "FLUXER_KV_URL:/run/fluxer-kv/FLUXER_KV_URL" (unit instance "api")
      .serviceConfig.LoadCredential
      && servicesWith instance "FLUXER_KV_PASSWORD" == [ ];
    "shared backing services listen on the shared address" =
      failed sharedBacking == [ ]
      && sharedBacking.services.nats.settings.host == "10.0.0.1"
      && sharedBacking.services.nats.settings.http == "127.0.0.1:8222"
      && sharedBacking.services.redis.servers.fluxer.bind == "10.0.0.1"
      && sharedBacking.services.meilisearch.listenAddress == "10.0.0.1"
      && sharedBacking.services.postgresql.settings.listen_addresses == "localhost,10.0.0.1"
      && lib.hasInfix "-s3.ip.bind=10.0.0.1" sharedBacking.systemd.services.fluxer-seaweedfs.serviceConfig.ExecStart
      && (env sharedBacking "api").FLUXER_NATS_URL == "nats://10.0.0.1:4222";
    "shared backing services take their clients only" =
      lib.hasInfix "host fluxer fluxer 10.0.0.2/32 scram-sha-256" sharedBacking.services.postgresql.authentication
      &&
        lib.all
          (
            port:
            lib.hasInfix "iptables -A nixos-fw -p tcp -s 10.0.0.2 --dport ${toString port} -j nixos-fw-accept" sharedBacking.networking.firewall.extraCommands
          )
          [
            5432
            6379
            4222
            7700
            8333
          ]
      && sharedBacking.services.fluxer.generate ? FLUXER_POSTGRES_PASSWORD;
    "sharing backing services on loopback is refused" =
      lib.any (lib.hasInfix "clients needs a listenAddress")
        (
          failed (eval {
            services.fluxer = {
              enable = true;
              domain = "chat.example.com";
              backingServices.clients = [ "10.0.0.2" ];
            };
          })
        );
    "a remote worker puts its key-value URL together" =
      failed remoteWorker == [ ]
      && lib.hasInfix "'%s://:%s@%s' redis \"$password\"" remoteWorker.systemd.services.fluxer-kv-url.script
      && lib.hasInfix "10.0.0.1:6379/0 >/run/fluxer-kv/FLUXER_KV_URL" remoteWorker.systemd.services.fluxer-kv-url.script
      && lib.elem "FLUXER_KV_URL:/run/fluxer-kv/FLUXER_KV_URL" (unit remoteWorker "worker")
      .serviceConfig.LoadCredential;
    "the module creates its own user and group" =
      instance.users.users.fluxer.isSystemUser
      && instance.users.users.fluxer.group == "fluxer"
      && instance.users.groups ? fluxer
      && (unit instance "api").serviceConfig.Group == "fluxer"
      && instance.systemd.slices ? system-fluxer
      && lib.all (name: instance.systemd.services.${name}.serviceConfig.Slice == "system-fluxer.slice") [
        "fluxer-api"
        "fluxer-gateway"
        "fluxer-secrets"
        "fluxer-seaweedfs"
        "fluxer-kv-url"
      ];
    "a user and group under other names are the operator's" =
      failed ownUser == [ ]
      && !ownUser.users.users.chat.isSystemUser
      && ownUser.users.users.chat.group == "users"
      && !(ownUser.users.users ? fluxer)
      && !(ownUser.users.groups ? fluxer)
      && (unit ownUser "api").serviceConfig.User == "chat"
      && (unit ownUser "api").serviceConfig.Group == "users"
      && map (u: u.name) ownUser.services.postgresql.ensureUsers == [ "chat" ];
    "the local database role has to be the services' user" =
      lib.any (lib.hasInfix "has to be services.fluxer.user")
        (
          failed (eval {
            services.fluxer = {
              enable = true;
              domain = "chat.example.com";
              postgres = {
                user = "chat";
                database = "chat";
              };
            };
          })
        );
    "the module's WireGuard tunnel connects every host" =
      let
        peers =
          config:
          map (p: {
            inherit (p)
              name
              publicKey
              endpoint
              allowedIPs
              persistentKeepalive
              ;
          }) config.networking.wireguard.interfaces.wg-fluxer.peers;
        main = tunnelMain.networking.wireguard.interfaces.wg-fluxer;
      in
      failed tunnelMain == [ ]
      && failed tunnelWorker == [ ]
      && main.ips == [ "10.77.0.1/32" ]
      && main.listenPort == 51820
      && main.privateKeyFile == "/run/secrets/wireguard"
      && lib.elem 51820 tunnelMain.networking.firewall.allowedUDPPorts
      &&
        peers tunnelMain == [
          {
            name = "worker";
            publicKey = "worker-key";
            endpoint = null;
            allowedIPs = [ "10.77.0.2/32" ];
            persistentKeepalive = null;
          }
        ]
      &&
        peers tunnelWorker == [
          {
            name = "main";
            publicKey = "main-key";
            endpoint = "main.example.com:51820";
            allowedIPs = [ "10.77.0.1/32" ];
            persistentKeepalive = 25;
          }
        ];
    "shared backing services and the gateway cluster use the tunnel" =
      tunnelMain.services.redis.servers.fluxer.bind == "10.77.0.1"
      && tunnelMain.services.postgresql.settings.listen_addresses == "localhost,10.77.0.1"
      && (env tunnelMain "gateway").FLUXER_ERLANG_NODE_NAME == "fluxer_gateway@10.77.0.1"
      &&
        lib.all
          (
            port:
            lib.hasInfix "iptables -A nixos-fw -i wg-fluxer -p tcp -s 10.77.0.2 --dport ${toString port} -j nixos-fw-accept" tunnelMain.networking.firewall.extraCommands
          )
          [
            5432
            6379
            9100
          ];
    "the services bind early only to a tunnel that comes up late" =
      nonlocalBind tunnelMain == null
      && nonlocalBind (tunnelHost "main" { networking.wireguard.useNetworkd = true; }) == 1
      && nonlocalBind tailscaleMain == 1;
    "a tunnel set up elsewhere scopes the shared ports to its interface" =
      failed tailscaleMain == [ ]
      && tailscaleMain.networking.wireguard.interfaces == { }
      && tailscaleMain.services.nats.settings.host == "100.64.0.1"
      && lib.hasInfix ''iifname "tailscale0" ip saddr { 100.64.0.2 } tcp dport { 5432, 6379, 4222, 7700, 8333 } accept'' tailscaleMain.networking.firewall.extraInputRules;
    "a host missing from the tunnel's hosts is refused" =
      lib.any (lib.hasInfix "no entry for this host, other")
        (failed (tunnelHost "other" { }));
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

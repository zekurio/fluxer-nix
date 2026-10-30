# Voice and video. Runs LiveKit through the nixpkgs module, configured the way
# upstream's compose file does, and tells the Fluxer API where to find it. The
# server and the API can live on different hosts: both sides share
# apiKey and apiSecretFile.
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
    mkOption
    types
    ;

  fluxer = config.services.fluxer;
  cfg = fluxer.livekit;

  keyFile = "/run/fluxer-livekit/keys.json";
  mapDefaults = lib.mapAttrs (_: lib.mkDefault);
in
{
  options.services.fluxer.livekit = {
    enable = mkOption {
      type = types.bool;
      default = fluxer.enable;
      defaultText = literalExpression "config.services.fluxer.enable";
      description = "Run a LiveKit server for Fluxer on this host.";
    };

    apiKey = mkOption {
      type = types.str;
      default = "fluxer";
      description = "The LiveKit API key Fluxer signs its requests with. It is not secret.";
    };

    apiSecretFile = mkOption {
      type = types.nullOr types.externalPath;
      default = fluxer.secretFiles.FLUXER_LIVEKIT_API_SECRET or null;
      defaultText = literalExpression "config.services.fluxer.secrets.FLUXER_LIVEKIT_API_SECRET, or a generated secret";
      example = "/run/agenix/fluxer-livekit";
      description = ''
        File holding the LiveKit API secret, at least 32 characters, such as
        the output of `openssl rand -hex 32`. The LiveKit server and the
        Fluxer API need the same secret.
      '';
    };

    url = mkOption {
      type = types.nullOr types.str;
      default =
        if cfg.enable && fluxer.edge.enable && fluxer.publicOrigin != null then
          "${fluxer.publicOrigin}/livekit"
        else
          null;
      defaultText = literalExpression ''"''${publicOrigin}/livekit" when LiveKit and the edge run on this host'';
      example = "wss://voice.example.com";
      description = ''
        The LiveKit address browsers connect to. Setting it turns on voice and
        video in the Fluxer API.
      '';
    };

    internalUrl = mkOption {
      type = types.nullOr types.str;
      default = if cfg.enable then "http://127.0.0.1:${toString cfg.port}" else null;
      defaultText = literalExpression ''
        if config.services.fluxer.livekit.enable then "http://127.0.0.1:''${toString port}" else null
      '';
      example = "http://10.0.0.3:7880";
      description = ''
        The LiveKit address the Fluxer API uses for server calls. Required when
        the LiveKit server runs on another host.
      '';
    };

    defaultRegion = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.str
          types.number
        ]
      );
      default = {
        id = "default";
        name = "Default";
        emoji = "🌍";
        latitude = 0;
        longitude = 0;
      };
      description = "The voice region the API seeds on every start.";
    };

    port = mkOption {
      type = types.port;
      default = 7880;
      description = ''
        Port of the LiveKit API and signalling WebSocket. Put a reverse proxy
        with TLS in front of it to serve {option}`services.fluxer.livekit.url`.
      '';
    };

    tcpPort = mkOption {
      type = types.port;
      default = 7881;
      description = "TCP port for media, used by clients that cannot reach the UDP port.";
    };

    udpPort = mkOption {
      type = types.port;
      default = 7882;
      description = "UDP port for media. All participants share this one port.";
    };

    nodeIP = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "203.0.113.10";
      description = "The IP address LiveKit advertises to clients. Null finds it through STUN when useExternalIP is on.";
    };

    useExternalIP = mkOption {
      type = types.bool;
      default = true;
      description = "Find the public IP address over STUN.";
    };

    stunServers = mkOption {
      type = types.listOf types.str;
      default = [
        "stun.l.google.com:19302"
        "stun1.l.google.com:19302"
      ];
      description = "STUN servers used to find the public IP address.";
    };

    webhookUrl = mkOption {
      type = types.nullOr types.str;
      default =
        if fluxer.api.enable then
          "${fluxer.endpoints.api}/webhooks/livekit"
        else if fluxer.publicOrigin != null then
          "${fluxer.publicOrigin}/api/webhooks/livekit"
        else
          null;
      defaultText = literalExpression ''
        the API on this host if it runs here, else "''${publicOrigin}/api/webhooks/livekit"
      '';
      example = "http://10.0.0.2:8080/webhooks/livekit";
      description = ''
        Where LiveKit reports room and participant events. The Fluxer API
        serves them at `/webhooks/livekit`, which is `/api/webhooks/livekit`
        on the public origin.
      '';
    };

    logLevel = mkOption {
      type = types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "LiveKit log level.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the media ports, tcpPort and udpPort. The signalling port stays closed.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.enable || cfg.url != null) -> cfg.apiSecretFile != null;
          message = "services.fluxer.livekit.apiSecretFile is required for voice.";
        }
        {
          assertion = cfg.url != null -> cfg.internalUrl != null;
          message = "services.fluxer.livekit.internalUrl is required when the LiveKit server runs on another host.";
        }
        {
          assertion = cfg.enable -> cfg.webhookUrl != null;
          message = "services.fluxer.livekit needs services.fluxer.domain or an explicit webhookUrl.";
        }
      ];

      services.fluxer.generate = lib.mkIf (cfg.enable || cfg.url != null) {
        FLUXER_LIVEKIT_API_SECRET = "hex32";
      };

      # What the Fluxer API reads. The API and worker units get the secret
      # themselves, see services.nix.
      services.fluxer.settings = mapDefaults (
        if cfg.url == null then
          { FLUXER_LIVEKIT_ENABLED = false; }
        else
          {
            FLUXER_LIVEKIT_ENABLED = true;
            FLUXER_LIVEKIT_URL = cfg.url;
            FLUXER_LIVEKIT_INTERNAL_URL = cfg.internalUrl;
            FLUXER_LIVEKIT_API_KEY = cfg.apiKey;
            FLUXER_LIVEKIT_DEFAULT_REGION = builtins.toJSON cfg.defaultRegion;
          }
      );
    }

    (mkIf cfg.enable {
      services.livekit = {
        enable = true;
        inherit keyFile;
        settings = {
          inherit (cfg) port;
          log_level = cfg.logLevel;
          rtc = {
            tcp_port = cfg.tcpPort;
            udp_port = cfg.udpPort;
            # LiveKit ignores udp_port when a port range is set, and the
            # nixpkgs module sets one by default.
            port_range_start = 0;
            port_range_end = 0;
            use_external_ip = cfg.useExternalIP;
            node_ip = cfg.nodeIP;
            stun_servers = cfg.stunServers;
          };
          webhook = {
            api_key = cfg.apiKey;
            urls = [ cfg.webhookUrl ];
          };
        };
      };

      # LiveKit wants "<key>: <secret>" pairs, the API wants the bare secret.
      # Build LiveKit's file from the one secret file both sides share. JSON is
      # valid YAML and quotes the secret safely.
      systemd.services.fluxer-livekit-keys = {
        description = "LiveKit key file for Fluxer";
        before = [ "livekit.service" ];
        after = lib.optional fluxer.generateSecrets "fluxer-secrets.service";
        wants = lib.optional fluxer.generateSecrets "fluxer-secrets.service";
        requiredBy = [ "livekit.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "secret:${cfg.apiSecretFile}" ];
          RuntimeDirectory = "fluxer-livekit";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          ExecStart = pkgs.writeShellScript "fluxer-livekit-keys" ''
            ${lib.getExe pkgs.jq} -n \
              --arg key ${lib.escapeShellArg cfg.apiKey} \
              --rawfile secret "$CREDENTIALS_DIRECTORY/secret" \
              '{($key): ($secret | rtrimstr("\n"))}' >${keyFile}
          '';
        };
      };

      # Restart LiveKit whenever the key file is rebuilt, such as after a
      # change of apiKey or a restart to pick up a rotated secret.
      systemd.services.livekit.partOf = [ "fluxer-livekit-keys.service" ];

      networking.firewall = mkIf cfg.openFirewall {
        allowedTCPPorts = [ cfg.tcpPort ];
        allowedUDPPorts = [ cfg.udpPort ];
      };
    })
  ];
}

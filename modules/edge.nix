# The public entry point: Caddy with the routes of upstream's edge Caddyfile.
# It also serves the static assets, which upstream runs as a second Caddy.
{
  config,
  lib,
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
  edge = cfg.edge;
  base = cfg.admin.basePath;

  proxy = target: "import fluxer_upstream ${target}";
in
{
  options.services.fluxer = {
    edge = {
      enable = mkOption {
        type = types.bool;
        default = cfg.enable;
        defaultText = literalExpression "config.services.fluxer.enable";
        description = ''
          Serve the instance on services.fluxer.domain with Caddy, which gets
          its certificate itself. To use another reverse proxy, turn this off
          and copy the routes from this module.
        '';
      };
      staticPackage = mkOption {
        type = types.package;
        default = fluxerPackages.fluxer-static;
        defaultText = literalExpression "fluxer-nix.packages.\${system}.fluxer-static";
        description = "The static assets to serve.";
      };
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open TCP ports 80 and 443, and UDP port 443 for HTTP/3.";
      };
    };

    endpoints = {
      gateway = mkOption {
        type = types.str;
        default = "http://${cfg.localAddress}:${toString cfg.gateway.port}";
        defaultText = lib.literalMD "`services.fluxer.gateway.port` on `services.fluxer.listenAddress`, or on loopback for a wildcard address";
        description = "Where the edge reaches the gateway.";
      };
      admin = mkOption {
        type = types.str;
        default = "http://${cfg.localAddress}:${toString cfg.admin.port}";
        defaultText = lib.literalMD "`services.fluxer.admin.port` on `services.fluxer.listenAddress`, or on loopback for a wildcard address";
        description = "Where the edge reaches the admin panel.";
      };
      appProxy = mkOption {
        type = types.str;
        default = "http://${cfg.localAddress}:${toString cfg.appProxy.port}";
        defaultText = lib.literalMD "`services.fluxer.appProxy.port` on `services.fluxer.listenAddress`, or on loopback for a wildcard address";
        description = "Where the edge reaches the web app.";
      };
      livekit = mkOption {
        type = types.nullOr types.str;
        default = if cfg.livekit.enable then "http://127.0.0.1:${toString cfg.livekit.port}" else null;
        defaultText = literalExpression "LiveKit on this host, if it runs here";
        description = "Where the edge sends /livekit. Null serves no such path.";
      };
    };
  };

  config = mkIf edge.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "services.fluxer.edge needs services.fluxer.domain.";
      }
    ];

    # The edge sets X-Forwarded-For, so the services trust it.
    services.fluxer.settings.FLUXER_TRUST_CLIENT_IP_HEADER = lib.mkDefault true;

    services.caddy = {
      enable = true;
      globalConfig = ''
        servers {
          trusted_proxies static private_ranges
          trusted_proxies_strict
        }
      '';
      extraConfig = ''
        (fluxer_upstream) {
          reverse_proxy {args[0]} {
            header_up X-Forwarded-For {client_ip}
            header_up X-Real-IP {client_ip}
            header_up -Forwarded
          }
        }
      '';
      virtualHosts.${cfg.domain}.extraConfig = ''
        encode zstd gzip

        handle /_health {
          respond "OK" 200
        }

        handle_path /api/* {
          ${proxy cfg.endpoints.api}
        }

        handle /gateway {
          rewrite * /
          ${proxy cfg.endpoints.gateway}
        }

        handle_path /gateway/* {
          ${proxy cfg.endpoints.gateway}
        }

        handle_path /media/* {
          ${proxy cfg.endpoints.mediaProxy}
        }

        ${lib.optionalString (cfg.endpoints.livekit != null) ''
          handle_path /livekit/* {
            ${proxy cfg.endpoints.livekit}
          }
        ''}

        handle ${base} {
          rewrite * /
          ${proxy cfg.endpoints.admin}
        }

        handle_path ${base}/* {
          ${proxy cfg.endpoints.admin}
        }

        # Upstream's static Caddyfile.
        @staticAssets path /web/* /emoji/* /libs/* /avatars/* /badges/* /desktop/*
        handle @staticAssets {
          root * ${edge.staticPackage}
          header {
            X-Content-Type-Options nosniff
            Referrer-Policy strict-origin-when-cross-origin
            X-Frame-Options DENY
            Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
            Access-Control-Allow-Origin *
            Cache-Control "public, max-age=3600, must-revalidate"
            -Server
          }
          @hashedBadges path_regexp ^/badges/[0-9a-f]{16}\.(webp|png)$
          header @hashedBadges {
            defer
            Cache-Control "public, max-age=31536000, immutable"
          }
          file_server
        }

        handle /.well-known/fluxer {
          ${proxy cfg.endpoints.api}
        }

        handle /.well-known/webfinger {
          ${proxy cfg.endpoints.api}
        }

        handle {
          ${proxy cfg.endpoints.appProxy}
        }
      '';
    };

    networking.firewall = mkIf edge.openFirewall {
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [ 443 ];
    };
  };
}

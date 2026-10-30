# A tunnel between the hosts of an instance: one the module sets up with
# WireGuard, or one that is already there, such as Tailscale or Nebula. The
# backing services and the gateway cluster listen on it and open their ports
# on it only.
{
  config,
  lib,
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
  tunnel = cfg.tunnel;
  wg = tunnel.wireguard;

  ipv4 = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";

  # nixpkgs' scripted WireGuard brings the interface up before network.target,
  # which every service that listens on the tunnel starts after.
  upBeforeNetwork = wg.enable && !config.networking.wireguard.useNetworkd;
in
{
  options.services.fluxer.tunnel = {
    address = mkOption {
      type = types.nullOr ipv4;
      default = if wg.enable then wg.hosts.${wg.name}.address or null else null;
      defaultText = lib.literalMD "this host's address in `wireguard.hosts`, with `wireguard.enable`";
      example = "100.64.0.1";
      description = ''
        This host's IPv4 address on a tunnel between the instance's hosts,
        such as WireGuard, Tailscale or Nebula. The gateway cluster listens on
        it, and so do the backing services when they are shared. They can
        start before the tunnel has the address, and take connections once it
        does.
      '';
    };

    interface = mkOption {
      type = types.nullOr types.str;
      default = if wg.enable then "wg-fluxer" else null;
      defaultText = literalExpression ''if wireguard.enable then "wg-fluxer" else null'';
      example = "tailscale0";
      description = ''
        The tunnel's network interface. The ports the module opens to other
        hosts, for the backing services and the gateway cluster, open on it
        only.
      '';
    };

    wireguard = {
      enable = lib.mkEnableOption ''
        a WireGuard tunnel between the hosts in `hosts`, on
        services.fluxer.tunnel.interface. Every host reaches every other one
        directly, so at least one of each pair needs an endpoint the other
        reaches'';

      hosts = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              address = mkOption {
                type = ipv4;
                example = "10.77.0.1";
                description = "The host's address in the tunnel.";
              };
              publicKey = mkOption {
                type = types.str;
                example = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=";
                description = "The host's public key, from `wg pubkey`.";
              };
              endpoint = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "worker.example.com:51820";
                description = ''
                  Where the other hosts reach the host, as host:port. Leave it
                  null for a host they cannot reach, such as one behind NAT;
                  it reaches them, and keeps the connection open.
                '';
              };
            };
          }
        );
        default = { };
        example = literalExpression ''
          {
            main = {
              address = "10.77.0.1";
              publicKey = "…";
              endpoint = "main.example.com:51820";
            };
            worker = {
              address = "10.77.0.2";
              publicKey = "…";
            };
          }
        '';
        description = ''
          Every host of the instance, this one included, by name. Give every
          host the same list, for example from a file they all import.
        '';
      };

      name = mkOption {
        type = types.str;
        default = config.networking.hostName;
        defaultText = literalExpression "config.networking.hostName";
        description = "This host's name in `hosts`.";
      };

      privateKeyFile = mkOption {
        type = types.externalPath;
        example = "/run/secrets/fluxer-wireguard";
        description = "This host's private key, from `wg genkey`.";
      };

      port = mkOption {
        type = types.port;
        default = 51820;
        description = "The UDP port the tunnel listens on.";
      };

      openFirewall = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Open the tunnel's UDP port. WireGuard answers only peers whose key
          it knows.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # A tunnel that comes up after the services, such as Tailscale's, gets
    # its address late. Allowing the bind lets them listen on it anyway.
    (mkIf (tunnel.address != null && !upBeforeNetwork) {
      boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = lib.mkDefault 1;
    })

    (mkIf wg.enable {
      assertions = [
        {
          assertion = wg.hosts ? ${wg.name};
          message = "services.fluxer.tunnel.wireguard.hosts has no entry for this host, ${wg.name}. Set services.fluxer.tunnel.wireguard.name to its name there.";
        }
        {
          assertion = tunnel.interface != null;
          message = "services.fluxer.tunnel.wireguard needs services.fluxer.tunnel.interface.";
        }
      ];

      networking.wireguard.interfaces = mkIf (wg.hosts ? ${wg.name} && tunnel.interface != null) {
        ${tunnel.interface} = {
          ips = [ "${wg.hosts.${wg.name}.address}/32" ];
          listenPort = wg.port;
          inherit (wg) privateKeyFile;
          peers = lib.mapAttrsToList (name: host: {
            inherit name;
            inherit (host) publicKey endpoint;
            allowedIPs = [ "${host.address}/32" ];
            # Keeps the way back open when this host is behind NAT.
            persistentKeepalive = if host.endpoint != null then 25 else null;
          }) (removeAttrs wg.hosts [ wg.name ]);
        };
      };

      networking.firewall.allowedUDPPorts = lib.optional wg.openFirewall wg.port;
    })
  ];
}

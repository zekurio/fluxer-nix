# The gateway's Erlang side: clustering with gateways on other hosts, and a
# command for the release's own tools.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkOption
    types
    ;

  cfg = config.services.fluxer;
  cluster = cfg.gateway.cluster;
  firewallRules = import ./firewall-rules.nix { inherit lib; };

  ipv4 = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
  nodeName = address: "fluxer_gateway@${address}";

  # The node settings the release's tools need to find the running node. The
  # cookie they read from its $HOME/.erlang.cookie.
  unitEnv = config.systemd.services.fluxer-gateway.environment;
  toolEnv = lib.filter (name: unitEnv ? ${name}) [
    "HOME"
    "FLUXER_ERLANG_NODE_NAME"
    "FLUXER_ERLANG_DIST_PORT"
    "FLUXER_ERLANG_DIST_INTERFACE"
    "ERL_DIST_PORT"
  ];
  runuser = "${pkgs.util-linux}/bin/runuser";
  ctl = pkgs.writeShellScriptBin "fluxer-gateway-ctl" ''
    # The release's commands for a running gateway, such as ping, pid and
    # rpc, as its user and with its node settings. Run it as root.
    set -eu
    out=$(${runuser} -u ${cfg.user} -- mktemp -d)
    trap 'rm -rf "$out"' EXIT
    ${runuser} -u ${cfg.user} -- env ${
      lib.concatMapStringsSep " " (
        name: lib.escapeShellArg "${name}=${lib.replaceStrings [ "%%" ] [ "%" ] unitEnv.${name}}"
      ) toolEnv
    } \
      RELX_OUT_FILE_PATH="$out" RELX_REPLACE_OS_VARS=true \
      ${cfg.gateway.package}/lib/fluxer_gateway/bin/fluxer_gateway "$@"
  '';
in
{
  options.services.fluxer.gateway.cluster = {
    enable = lib.mkEnableOption ''
      clustering with the gateways on other hosts. The nodes connect over
      Erlang distribution, which is not encrypted, and whoever holds the cookie
      can run code on every node. Run it on a private network, such as the
      one in services.fluxer.tunnel, and give every node the same
      services.fluxer.secrets.FLUXER_ERLANG_COOKIE'';

    address = mkOption {
      type = types.nullOr ipv4;
      default = cfg.tunnel.address;
      defaultText = lib.literalExpression "config.services.fluxer.tunnel.address";
      example = "10.0.0.2";
      description = ''
        This host's IPv4 address on the network the gateways share. The node is
        named `fluxer_gateway@<address>`, and its distribution port,
        services.fluxer.gateway.distributionPort, listens there. Every node
        uses the same distribution port.
      '';
    };

    peers = mkOption {
      type = types.listOf ipv4;
      default = [ ];
      example = [
        "10.0.0.2"
        "10.0.0.3"
      ];
      description = ''
        The addresses of the gateways to cluster with. The list may include
        this host's own address, so every host can share it.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the distribution port to the peers, and to nothing else. With
        services.fluxer.tunnel.interface, it opens on the tunnel only.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.gateway.enable {
      environment.systemPackages = [ ctl ];
    })

    (mkIf (cfg.gateway.enable && cluster.enable) {
      assertions = [
        {
          assertion = cluster.address != null;
          message = "services.fluxer.gateway.cluster needs this host's address, services.fluxer.gateway.cluster.address.";
        }
        {
          assertion = cfg.secrets ? FLUXER_ERLANG_COOKIE || cfg.gateway.secrets ? FLUXER_ERLANG_COOKIE;
          message = ''
            A gateway cluster needs the same Erlang cookie on every node. Give it as
            a file in services.fluxer.secrets.FLUXER_ERLANG_COOKIE; a generated one
            differs from host to host.
          '';
        }
      ];

      services.fluxer.gateway.settings = lib.mapAttrs (_: lib.mkDefault) (
        {
          FLUXER_GATEWAY_CLUSTER_ENABLED = true;
        }
        // lib.optionalAttrs (cluster.address != null) {
          FLUXER_ERLANG_NODE_NAME = nodeName cluster.address;
          FLUXER_ERLANG_DIST_INTERFACE = "{${lib.replaceStrings [ "." ] [ "," ] cluster.address}}";
        }
        // lib.optionalAttrs (cluster.peers != [ ]) {
          FLUXER_GATEWAY_CLUSTER_STATIC_PEERS = lib.concatMapStringsSep "," nodeName cluster.peers;
        }
      );

      networking.firewall = mkIf cluster.openFirewall (firewallRules {
        inherit config;
        inherit (cfg.tunnel) interface;
        addresses = cluster.peers;
        ports = [ cfg.gateway.distributionPort ];
      });
    })
  ];
}

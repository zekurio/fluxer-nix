# An instance on two hosts. The server shares its backing services and runs
# the API, a gateway and the edge; node2 runs a second gateway, clustered
# with the first, and the instance's worker, against the server's backing
# services.
{ pkgs, module }:

let
  inherit (pkgs) lib;
  domain = "chat.example.test";
  ip = nodes: name: nodes.${name}.networking.primaryIPAddress;

  shared =
    { nodes, config, ... }:
    {
      imports = [ module ];
      # A cluster needs the cookie given, not generated. Test secrets may sit
      # in the store.
      environment.etc."fluxer/FLUXER_ERLANG_COOKIE" = {
        text = "cookie-shared-by-both-gateways";
        mode = "0400";
      };
      services.fluxer = {
        inherit domain;
        secrets.FLUXER_ERLANG_COOKIE = "/etc/fluxer/FLUXER_ERLANG_COOKIE";
        listenAddress = config.networking.primaryIPAddress;
        gateway.cluster = {
          enable = true;
          address = config.networking.primaryIPAddress;
          peers = map (ip nodes) [
            "server"
            "node2"
          ];
          openFirewall = true;
        };
      };
      environment.systemPackages = [ pkgs.curl ];
    };
in
pkgs.testers.runNixOSTest {
  name = "fluxer-multi-host";

  nodes.server =
    { nodes, config, ... }:
    {
      imports = [ shared ];
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 8192;
      };

      services.fluxer = {
        enable = true;
        backingServices = {
          listenAddress = config.networking.primaryIPAddress;
          clients = [ (ip nodes "node2") ];
        };
        # The worker runs on node2. Left out to keep the test small.
        worker.enable = false;
        livekit.enable = false;
        push.enable = false;
        admin.enable = false;
        appProxy.enable = false;
        mediaProxy.enable = false;
        endpoints.gateway = map (n: "http://${ip nodes n}:8081") [
          "server"
          "node2"
        ];
      };
      # node2's gateway asks the API for its configuration.
      networking.firewall.allowedTCPPorts = [ 8080 ];

      services.caddy.globalConfig = lib.mkAfter "local_certs";
      networking.hosts."127.0.0.1" = [ domain ];
    };

  nodes.node2 =
    { nodes, ... }:
    let
      server = ip nodes "server";
      # The server's generated secrets, copied over by the test script.
      copied = lib.filter (n: n != "FLUXER_KV_PASSWORD") (
        lib.attrNames (removeAttrs nodes.server.services.fluxer.generate [ "FLUXER_ERLANG_COOKIE" ])
      );
    in
    {
      imports = [ shared ];
      virtualisation = {
        memorySize = 2560;
        cores = 2;
      };

      services.fluxer = {
        gateway.enable = true;
        worker.enable = true;
        secrets = lib.genAttrs copied (name: "/var/lib/fluxer-secrets/${name}");
        postgres.host = server;
        valkey = {
          url = "redis://${server}:6379/0";
          passwordFile = "/var/lib/fluxer-secrets/FLUXER_KV_PASSWORD";
        };
        nats.url = "nats://${server}:4222";
        search.url = "http://${server}:7700";
        s3.endpoint = "http://${server}:8333";
        endpoints.api = "http://${server}:8080";
      };

      # Started by the test once the secrets are here.
      systemd.services = lib.genAttrs [ "fluxer-gateway" "fluxer-worker" "fluxer-kv-url" ] (_: {
        wantedBy = lib.mkForce [ ];
      });

      # For the edge on the server.
      networking.firewall.allowedTCPPorts = [ 8081 ];
    };

  testScript =
    { nodes, ... }:
    ''
      ips = {
          server: "${ip nodes "server"}",
          node2: "${ip nodes "node2"}",
      }
      server_ip = ips[server]

      start_all()

      with subtest("the server's backing services refuse clients without credentials"):
          server.wait_for_unit("fluxer-api.service")
          node2.wait_for_unit("multi-user.target")
          node2.succeed(
              f"timeout 5 bash -c 'exec 3<>/dev/tcp/{server_ip}/4222; head -c 2048 <&3'"
              " | grep -F '\"auth_required\":true'"
          )
          node2.succeed(
              f"timeout 5 bash -c 'exec 3<>/dev/tcp/{server_ip}/6379; printf \"PING\\r\\n\" >&3; head -n 1 <&3'"
              " | grep -F NOAUTH"
          )
          # Only S3 is shared, not the SeaweedFS master.
          node2.succeed(f"curl -s -o /dev/null --max-time 5 http://{server_ip}:8333")
          node2.fail(f"curl -s -o /dev/null --max-time 5 http://{server_ip}:9333")

      with subtest("node2 gets the server's secrets"):
          node2.succeed("install -d -m 700 /var/lib/fluxer-secrets")
          for name in server.succeed("ls /var/lib/fluxer-secrets").split():
              value = server.succeed(f"base64 -w0 /var/lib/fluxer-secrets/{name}").strip()
              node2.succeed(f"(umask 077; echo {value} | base64 -d >/var/lib/fluxer-secrets/{name})")
          node2.succeed("systemctl start fluxer-kv-url.service fluxer-gateway.service fluxer-worker.service")

      with subtest("the worker on node2 uses the server's backing services"):
          node2.wait_until_succeeds("journalctl -u fluxer-worker | grep -q 'Cron scheduler started'", timeout=300)
          node2.succeed("test \"$(systemctl show -P NRestarts fluxer-worker)\" = 0")

      with subtest("both gateways run"):
          for machine, ip in ips.items():
              machine.wait_for_unit("fluxer-gateway.service")
              machine.wait_until_succeeds(f"curl -fsS http://{ip}:8081/_health", timeout=300)

      with subtest("the gateways join each other"):
          for machine, other in [(server, node2), (node2, server)]:
              machine.wait_until_succeeds(
                  f"fluxer-gateway-ctl rpc erlang nodes | grep -F 'fluxer_gateway@{ips[other]}'",
                  timeout=120,
              )

      with subtest("distribution listens on the cluster address only"):
          for machine, ip in ips.items():
              machine.succeed(f"ss -Htln 'sport = :9100' | grep -q '{ip}:9100'")
              machine.fail("ss -Htln 'sport = :9100' | grep -Eq '(0\\.0\\.0\\.0|\\[::\\]|\\*):9100'")
              machine.fail("ss -Htln 'sport = :4369' | grep -q .")

      with subtest("the edge serves the gateway from either host"):
          server.wait_for_unit("caddy.service")
          edge = "curl -fsSk --resolve ${domain}:443:127.0.0.1 https://${domain}/gateway/_health"
          server.wait_until_succeeds(edge, timeout=300)
          server.systemctl("stop fluxer-gateway.service")
          for _ in range(10):
              server.succeed(edge)
          server.systemctl("start fluxer-gateway.service")
          node2.wait_until_succeeds(
              f"fluxer-gateway-ctl rpc erlang nodes | grep -F 'fluxer_gateway@{server_ip}'",
              timeout=120,
          )
    '';
}

# A whole instance on one host, with generated secrets, checked through its
# health endpoints and the edge.
{ pkgs, module }:

pkgs.testers.runNixOSTest {
  name = "fluxer-instance";

  nodes.server =
    { lib, ... }:
    {
      imports = [ module ];

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        diskSize = 8192;
      };

      services.fluxer = {
        enable = true;
        domain = "chat.example.test";
        # The test network has no STUN server.
        livekit.useExternalIP = false;
      };

      # No ACME in the test network: Caddy signs with its own CA.
      services.caddy.globalConfig = lib.mkAfter "local_certs";
      networking.hosts."127.0.0.1" = [ "chat.example.test" ];

      environment.systemPackages = [ pkgs.curl ];
    };

  testScript =
    { nodes, ... }:
    let
      gateway = nodes.server.services.fluxer.gateway;
    in
    ''
      import json

      server.wait_for_unit("fluxer-secrets.service")
      server.succeed("test \"$(stat -c %a /var/lib/fluxer-secrets)\" = 700")

      with subtest("backing services"):
          for unit in ["postgresql.service", "redis-fluxer.service", "nats.service",
                       "meilisearch.service", "fluxer-seaweedfs-init.service", "livekit.service"]:
              server.wait_for_unit(unit)

      def health(port, path="/_health"):
          server.wait_until_succeeds(f"curl -fsS http://127.0.0.1:{port}{path}", timeout=300)

      with subtest("internal services"):
          for name, port in [("gifs", 8091), ("messages", 8092), ("snowflakes", 8093),
                             ("unfurl", 8094), ("users", 8095)]:
              server.wait_for_unit(f"fluxer-{name}.service")
              health(port)

      with subtest("api and worker"):
          server.wait_for_unit("fluxer-api.service")
          health(8080)
          server.wait_for_unit("fluxer-worker.service")

      with subtest("gateway"):
          server.wait_for_unit("fluxer-gateway.service")
          health(8081)

      with subtest("media proxy, push, admin, web app"):
          server.wait_for_unit("fluxer-media-proxy.service")
          health(8083)
          server.wait_for_unit("fluxer-push.service")
          server.wait_for_unit("fluxer-admin.service")
          health(8084)
          server.wait_for_unit("fluxer-app-proxy.service")
          health(8085, "/_ready")

      with subtest("edge"):
          server.wait_for_unit("caddy.service")
          edge = "curl -fsSk --resolve chat.example.test:443:127.0.0.1 https://chat.example.test"
          server.wait_until_succeeds(f"{edge}/_health", timeout=120)
          server.succeed(f"{edge}/api/_health")
          server.succeed(f"{edge}/avatars/0.png -o /dev/null")
          server.succeed(f"{edge}/ -o /tmp/index.html")
          server.succeed("grep -qi '<html' /tmp/index.html")
          discovery = json.loads(server.succeed(f"{edge}/.well-known/fluxer"))
          print(json.dumps(discovery, indent=2)[:2000])

      with subtest("services listen on loopback only"):
          for port in [8080, 8081, ${toString gateway.distributionPort}]:
              server.succeed(f"ss -Htln 'sport = :{port}' | grep -q '127.0.0.1:{port}'")
              server.fail(f"ss -Htln 'sport = :{port}' | grep -Eq '(0\\.0\\.0\\.0|\\[::\\]|\\*):{port}'")
          # No epmd: the release gives the node its distribution port.
          server.fail("ss -Htln 'sport = :4369' | grep -q .")

      with subtest("the Erlang cookie stays off command lines"):
          cookie = "/var/lib/fluxer-secrets/FLUXER_ERLANG_COOKIE"
          # -f keeps the cookie out of grep's own command line.
          server.fail(f"grep -qaFf {cookie} /proc/[0-9]*/cmdline")
          server.fail(f"grep -qaFf {cookie} /proc/$(systemctl show -P MainPID fluxer-gateway)/environ")
          server.succeed("test \"$(stat -c %a /run/fluxer-gateway/.erlang.cookie)\" = 600")
          # The release's own tools still find the node, with the cookie file.
          pong = server.succeed("fluxer-gateway-ctl ping")
          assert "pong" in pong, pong

      with subtest("statement statistics"):
          server.succeed("runuser -u fluxer -- psql -d fluxer -tAc 'SELECT count(*) FROM pg_stat_statements'")

      with subtest("no startup warnings"):
          for unit, line in [
              ("fluxer-app-proxy", "ignoring invalid app proxy environment value"),
              ("fluxer-api", "could not enable pg_stat_statements"),
              ("fluxer-worker", "could not enable pg_stat_statements"),
              ("fluxer-push", "internal rpc retrying"),
              ("fluxer-gateway", "failed to fetch from API"),
          ]:
              server.fail(f"journalctl -b -u {unit} | grep -qi '{line}'")
    '';
}

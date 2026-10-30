# A host that runs only LiveKit for an instance whose API lives elsewhere.
{ pkgs, module }:

let
  secret = "0123456789abcdef0123456789abcdef0123456789abcdef";
in
pkgs.testers.runNixOSTest {
  name = "fluxer-livekit";

  nodes.voice =
    { config, lib, ... }:
    {
      imports = [ module ];

      services.fluxer = {
        domain = "chat.example.test";
        livekit = {
          enable = true;
          apiSecretFile = "/etc/fluxer/livekit-secret";
          # The test network has no STUN server.
          useExternalIP = false;
          # Stands in for the API on another host.
          webhookUrl = "http://127.0.0.1:9000/webhooks/livekit";
          openFirewall = true;
        };
      };

      # Secrets as a secret manager would leave them: owned by root, mode 0400.
      environment.etc."fluxer/livekit-secret" = {
        text = "${secret}\n";
        mode = "0400";
      };
      environment.etc."fluxer/probe-secret" = {
        text = "probe-value\n";
        mode = "0400";
      };

      # Records every request LiveKit sends to the webhook.
      systemd.services.webhook-sink = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.StateDirectory = "webhook-sink";
        script = ''
          exec ${lib.getExe pkgs.python3} - <<'EOF'
          import http.server, json

          class Handler(http.server.BaseHTTPRequestHandler):
              def do_POST(self):
                  body = self.rfile.read(int(self.headers["Content-Length"]))
                  with open("/var/lib/webhook-sink/requests.jsonl", "a") as f:
                      f.write(json.dumps({
                          "path": self.path,
                          "authorization": self.headers.get("Authorization"),
                          "body": body.decode(),
                      }) + "\n")
                  self.send_response(200)
                  self.end_headers()

          http.server.HTTPServer(("127.0.0.1", 9000), Handler).serve_forever()
          EOF
        '';
      };

      # Checks what a Fluxer unit sees: shared settings, and a root-only
      # secret read through FLUXER_<NAME>_FILE by an unprivileged user.
      systemd.services.fluxer-env-probe = lib.mkMerge [
        (config.services.fluxer.serviceEnv {
          secrets.FLUXER_PROBE_SECRET = "/etc/fluxer/probe-secret";
        })
        {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
          };
          script = ''
            set -eu
            test "$FLUXER_PROBE_SECRET_FILE" = "$CREDENTIALS_DIRECTORY/FLUXER_PROBE_SECRET"
            test "$(cat "$FLUXER_PROBE_SECRET_FILE")" = probe-value
            test -z "''${FLUXER_PROBE_SECRET:-}"
            test "$FLUXER_BASE_DOMAIN" = chat.example.test
            test "$FLUXER_PUBLIC_ORIGIN" = https://chat.example.test
            test "$FLUXER_SELF_HOSTED" = true
            test "$FLUXER_LIVEKIT_ENABLED" = false
          '';
        }
      ];

      environment.systemPackages = [ pkgs.livekit-cli ];
    };

  testScript = ''
    import base64, hashlib, hmac, json

    secret = "${secret}"

    def b64decode(part):
        return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))

    voice.wait_for_unit("fluxer-env-probe.service")

    voice.wait_for_unit("livekit.service")
    voice.wait_for_open_port(7880)

    with subtest("key file"):
        voice.succeed("test \"$(stat -c %a /run/fluxer-livekit/keys.json)\" = 600")
        keys = json.loads(voice.succeed("cat /run/fluxer-livekit/keys.json"))
        assert keys == {"fluxer": secret}, keys

    with subtest("media ports"):
        voice.succeed("ss -Htln 'sport = :7881' | grep -q LISTEN")
        udp = voice.succeed("ss -Hulnp")
        assert ":7882 " in udp, udp
        # One UDP port for all media, not nixpkgs' default range.
        assert ":50000 " not in udp, udp

    with subtest("signed webhook"):
        voice.succeed(f"lk room create --url http://127.0.0.1:7880 --api-key fluxer --api-secret {secret} test-room")
        voice.wait_until_succeeds("grep -q room_started /var/lib/webhook-sink/requests.jsonl")
        requests = [json.loads(line) for line in voice.succeed("cat /var/lib/webhook-sink/requests.jsonl").splitlines()]
        request = next(r for r in requests if "room_started" in r["body"])
        assert request["path"] == "/webhooks/livekit", request["path"]

        header, payload, signature = request["authorization"].removeprefix("Bearer ").split(".")
        expected = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
        assert hmac.compare_digest(b64decode(signature), expected), "webhook not signed with the shared secret"
        claims = json.loads(b64decode(payload))
        assert claims["iss"] == "fluxer", claims
        body_hash = base64.b64encode(hashlib.sha256(request["body"].encode()).digest()).decode()
        assert claims["sha256"] == body_hash, claims

    with subtest("rebuilding the key file restarts LiveKit"):
        before = voice.succeed("systemctl show -P MainPID livekit.service").strip()
        voice.succeed("systemctl restart fluxer-livekit-keys.service")
        voice.wait_for_unit("livekit.service")
        after = voice.succeed("systemctl show -P MainPID livekit.service").strip()
        assert before != after, "LiveKit kept running with the old key file"
  '';
}

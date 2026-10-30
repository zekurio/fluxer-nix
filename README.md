# fluxer-nix

Nix packaging for [Fluxer](https://fluxer.app): the desktop client, and NixOS
modules for running an instance. Each part of an instance is enabled
separately, so a host can run only the parts it needs.

The service packages and modules are new and not yet proven on a real
instance. See [Status](#status).

## Desktop client

`fluxer-desktop` repackages the official stable Linux build for `x86_64-linux`
and `aarch64-linux`. Upstream builds its Linux shell on a patched Electron, so
the package uses their binary rather than nixpkgs' Electron.

```nix
{
  inputs.fluxer-nix.url = "github:zekurio/fluxer-nix";

  outputs = { nixpkgs, fluxer-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        { nixpkgs.overlays = [ fluxer-nix.overlays.default ]; }
        ({ pkgs, ... }: { environment.systemPackages = [ pkgs.fluxer-desktop ]; })
      ];
    };
  };
}
```

To try it without installing it: `nix run github:zekurio/fluxer-nix#fluxer-desktop`.

### Package arguments

Set these with `pkgs.fluxer-desktop.override { ... }`.

| Argument | Default | Effect |
| --- | --- | --- |
| `disableUpdates` | `true` | Keeps the client on the renderer shipped in this package. See below. |
| `hunspellDictionaries` | `[ ]` | Spellcheck dictionaries, e.g. `[ pkgs.hunspellDicts.en_US ]`. Dictionaries under `$XDG_DATA_DIRS/hunspell` are found too. |
| `withTTS` | `true` | Text-to-speech through speech-dispatcher. |
| `commandLineArgs` | `""` | Extra Chromium or Fluxer switches. |

`NIXOS_OZONE_WL=1` adds the usual Wayland window decoration and IME switches.
Electron already picks Wayland on its own when it is available.

### Changes from the upstream build

- **Updates.** Upstream ships the renderer as a bundled copy plus "modules"
  that the client downloads into `~/.config/Fluxer` and prefers when they are
  newer. With `disableUpdates` the wrapper passes
  `--fluxer-disable-module-updates`, upstream's own switch. The client then
  starts on the bundled renderer, makes no manifest requests, stops polling for
  updates, and hides "Check for updates". The cost: optional modules that
  normally download on demand are unavailable. These are CJK fonts, spellcheck
  dictionaries (use `hunspellDictionaries` instead), code highlighting
  grammars, noise suppression and camera effects. Modules downloaded by an
  earlier unpinned install stay in use while they are newer than the bundled
  renderer. Delete `~/.config/Fluxer/modules` to drop them.
- **Launch path.** The client writes an autostart entry on first launch (on by
  default upstream) and falls back to writing its own menu entry. Both used
  `process.execPath`, which here is the unwrapped binary in the store. That
  path skips the wrapper and disappears after an update. The build patches the
  minified main bundle to use the `fluxer-desktop` command instead, and fails if
  the pattern stops matching. The wrapper also puts the package's
  `share/` on `XDG_DATA_DIRS`, so the client sees the packaged
  `app.fluxer.FluxerDesktop.desktop` entry and leaves `~/.local/share` alone.
- **Libraries.** The WebAuthn addon is linked against nixpkgs' `libfido2`
  instead of its bundled libfido2, OpenSSL, libudev, zlib and libcbor. The
  bundled Vulkan loader is replaced with nixpkgs' loader, which finds drivers
  under `/run/opengl-driver`. The setuid `chrome-sandbox` is removed: Chromium
  uses user namespaces, or `security.chromiumSuidSandbox` on NixOS.

### Updating

```sh
./pkgs/fluxer-desktop/update.sh
```

The script reads the version and tarball checksums from the feed the client
polls (`pkgs.fluxer.com`). It refuses to write a pin unless GitHub reports the
same digest for the release asset.

## Self-hosting

```nix
{
  inputs.fluxer-nix.url = "github:zekurio/fluxer-nix";

  outputs = { nixpkgs, fluxer-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [ fluxer-nix.nixosModules.default ./host.nix ];
    };
  };
}
```

The service packages are built from source with this flake's nixpkgs. Each
`services.fluxer.<service>.package` option can point elsewhere, for example at
`pkgs.fluxer-api` from the overlay.

### One host

```nix
services.fluxer = {
  enable = true;
  domain = "chat.example.com";
  edge.openFirewall = true;       # TCP 80 and 443, UDP 443
  livekit.openFirewall = true;    # TCP 7881, UDP 7882
};
```

This runs every Fluxer service, along with:
- PostgreSQL, Valkey, NATS with JetStream, Meilisearch, and SeaweedFS as the S3
  store, set up the way upstream's compose file sets them up;
- LiveKit for voice;
- Caddy on the domain, with a certificate from Let's Encrypt.

Secrets that `services.fluxer.secrets` leaves out are generated once into
`/var/lib/fluxer-secrets`. Back that directory up: the stored data depends on
some of them. Open the domain and sign in with the setup token from
`/var/lib/fluxer-secrets/FLUXER_SETUP_TOKEN` to create the admin account.

### Services

Each service has `services.fluxer.<service>.enable`, `package`, `port`,
`settings` and `secrets`:

| Option | Unit | Port |
| --- | --- | --- |
| `api` | `fluxer-api` | 8080 |
| `worker` | `fluxer-worker` | none; run exactly one per instance |
| `gateway` | `fluxer-gateway` | 8081, Erlang distribution on 9100 |
| `mediaProxy` | `fluxer-media-proxy` | 8083 |
| `admin` | `fluxer-admin` | 8084 |
| `appProxy` | `fluxer-app-proxy` | 8085 |
| `push` | `fluxer-push` | 8126 |
| `gifs`, `messages`, `snowflakes`, `unfurl`, `users` | `fluxer-<name>` | 8091 to 8095 |

They listen on `services.fluxer.listenAddress`, 127.0.0.1 by default, and
the services on one host reach each other there, or on loopback for `0.0.0.0`
or `::`. The gateway's Erlang distribution port listens on loopback only, and
no epmd runs, so the gateway cannot join a cluster. The five internal services
talk to the rest over NATS. Each runs its router and shard in one process.

On one host the API counts as started once it answers, so the services that
need it at startup, the gateway and push among them, start after that.

The backing services each have `createLocally` (`seaweedfs.enable` for S3), on
with `services.fluxer.enable`, and an address for a server elsewhere:
`services.fluxer.postgres`, `valkey`, `nats`, `search` and `s3`.
`services.fluxer.endpoints` says where the services and the edge reach one
another when they run on different hosts.

`services.fluxer.edge` is Caddy with upstream's routes. It also serves the
static assets directly, where upstream runs a second Caddy. To use another
reverse proxy, turn it off and copy the routes from `modules/edge.nix`.

### Configuration and secrets

`services.fluxer.domain` is the instance's public hostname. Every host that
runs a part of the instance sets the same value. Other settings go in
`services.fluxer.settings`, under the variable names from the configuration
page of the [operator docs](https://docs.fluxer.app/operator/).

Secrets are files. Every Fluxer service reads `FLUXER_<NAME>_FILE` in place of
`FLUXER_<NAME>`, so a secret never has to be in the Nix store or in an
environment file. The modules hand each file to its service as a systemd
credential, which lets the file stay readable by root only. Any tool that
puts a file on the host works:

```nix
services.fluxer.secrets = {
  FLUXER_SUDO_MODE_SECRET = config.age.secrets.fluxer-sudo-mode.path;      # agenix
  FLUXER_GATEWAY_RPC_AUTH_TOKEN = config.sops.secrets.fluxer-rpc.path;     # sops-nix
};
```

The backing services read theirs from the same place:
`FLUXER_SEARCH_API_KEY` is the Meilisearch master key,
`FLUXER_S3_SECRET_ACCESS_KEY` the S3 key, and `FLUXER_POSTGRES_PASSWORD` the
password of a database elsewhere. The local database needs none: the services
run as the `fluxer` user and connect over the Unix socket. It also collects
query statistics with `pg_stat_statements`, as upstream's image does; turn
that off with `services.fluxer.postgres.statementStats`.

A secret replaces the setting of the same name, so a value that carries a
password, such as `FLUXER_KV_URL` or `FLUXER_POSTGRES_URL`, can be given as a
file.

`services.fluxer.generateSecrets` fills in the missing ones, and is on with
`services.fluxer.enable`. Hosts that share an instance need the same secrets,
so with several hosts give every secret as a file and leave it off. The list
is `generate` in `modules/fluxer.nix` and `modules/infra.nix`.

Options that take a secret file reject a path in the Nix store, including a
Nix path literal such as `./secret`, which Nix would copy into the store.

Each service gets only the secrets it reads, listed per service in
`modules/services.nix`; the web app gets none. A secret no service is known to
read, such as an SMTP password, goes to the API and the worker, which read most
of the configuration. Those two still get most secrets, because upstream's
configuration loader refuses to start without them. To hand a secret to
another service as well, set it in that service's `secrets` option.

### Voice

`services.fluxer.livekit` runs LiveKit through the nixpkgs module, set up the
way upstream's compose file does: one UDP port and one TCP port for media, and
room events sent to the Fluxer API. LiveKit and the API share a key name
(`apiKey`, `fluxer` by default) and one secret,
`FLUXER_LIVEKIT_API_SECRET`. Generate it with `openssl rand -hex 32`.

On a single host, browsers reach LiveKit through the edge at `/livekit`, and
LiveKit sends events straight to the local API.

A host that runs only LiveKit:

```nix
services.fluxer = {
  domain = "chat.example.com";
  livekit = {
    enable = true;
    apiSecretFile = config.age.secrets.fluxer-livekit.path;
    openFirewall = true; # TCP 7881 and UDP 7882
  };
};

# Clients connect to the signalling port over TLS.
services.caddy.virtualHosts."voice.example.com".extraConfig = ''
  reverse_proxy 127.0.0.1:7880
'';
```

LiveKit sends room events to `https://chat.example.com/api/webhooks/livekit`.
Set `livekit.webhookUrl` to reach the API another way. The host that runs the
API points at the LiveKit host:

```nix
services.fluxer = {
  domain = "chat.example.com";
  livekit = {
    url = "wss://voice.example.com";
    internalUrl = "http://10.0.0.3:7880";
    apiSecretFile = config.age.secrets.fluxer-livekit.path;
  };
};
```

The nixpkgs LiveKit module sets an ICE port range by default, and LiveKit then
ignores its single UDP port. `services.fluxer.livekit` clears that range. If
you configure `services.livekit` yourself, note that LiveKit's startup log
still reports the UDP port in that case.

### Pinned release

Upstream releases an instance as a set of component images,
`fluxer-release@<version>`. A component that did not change keeps its earlier
build, so one release can span several source commits. `pkgs/fluxer/release.json`
records each component's version and commit from the release manifest, and
every package builds from the commit upstream built its image from.

```sh
./pkgs/fluxer/update.sh
```

The script pins the newest release, prefetches each new commit, and refetches
the dependency hashes (Cargo vendor directories, pnpm stores, rebar3
dependencies, spellcheck dictionaries) of components whose commit changed.

### Packages

| Package | Built from |
| --- | --- |
| `fluxer-api` | TypeScript, bundled with esbuild; also provides `fluxer-worker` |
| `fluxer-gateway` | Erlang release with two Rust NIFs, wrapped in upstream's entrypoint |
| `fluxer-web` | The web app, built the way the self-hosted app-proxy image builds it |
| `fluxer-app-proxy` | The Rust server for `fluxer-web` |
| `fluxer-static` | Avatars, badges, emoji and the desktop spellcheck dictionaries |
| `fluxer-media-proxy` | Rust, linked against nixpkgs' ffmpeg 9, libvips, libheif and libyuv |
| `fluxer-admin`, `fluxer-push`, `fluxer-gifs`, `fluxer-messages`, `fluxer-snowflakes`, `fluxer-unfurl`, `fluxer-users` | Rust |

Everything builds without network access, from fixed-output dependencies.
The API and the gateway carry small patches, in their package directories: a
listen address for both; the gateway's Erlang cookie in a file instead of on
its command line, where `ps` showed it; and the gateway fetching its rollout
configuration again until the API answers, where it gave up after one try.
`fluxer-web` matches upstream's image except the WASM modules, which come out
slightly different because nixpkgs compiles them with Rust 1.99 where upstream
uses 1.98.1. The Rust services use upstream's release profile with full LTO,
so they take a while to build.

### Tests

`nix flake check` builds the packages and runs:

- `eval`: option logic, such as the settings an API host renders for a remote
  LiveKit server, a whole instance's units and their secrets, and the refusal
  of secrets in the Nix store.
- `livekit`: a VM that runs only LiveKit. It checks the key file, the media
  ports, that a room creates a webhook signed with the shared secret, and that
  a service running as a dynamic user reads a root-only secret through
  `FLUXER_<NAME>_FILE`.
- `instance`: a VM with a whole instance and generated secrets, checked
  through every service's health endpoint and the edge. It also checks that
  the services listen on loopback only, that no process shows the Erlang
  cookie on its command line, that `pg_stat_statements` works, and that no
  service logs one of the startup warnings it used to.

### Status

Verified, by the `instance` test: every package builds without network
access, a whole instance boots on one host with generated secrets, every
service passes its health check, and the edge serves the web app, the static
assets, the API and the instance's discovery document.

Not verified yet: signing up and signing in, messages over the gateway, voice
calls, uploads through the media proxy, push notifications, an instance spread
over several hosts, and `aarch64-linux`.

Known issues:

- The API and the worker still get most secrets, because upstream's
  configuration loader refuses to start without them, even ones they never use
  such as `FLUXER_ADMIN_SECRET_KEY_BASE`.
- The lists of secrets per service are read off upstream's source by hand. A
  release that makes a service read a new secret needs the list updated, or
  that service will not get it.
- The gateway's Erlang distribution is on loopback, so it cannot join a
  cluster. The release's `ping` and `rpc` commands still work, as the `fluxer`
  user with the unit's environment, but they pass the cookie on the command
  line of `erl_call` while they run.
- Ordering push and the gateway after the API only works on one host.
  Elsewhere push fetches its configuration again every 30 seconds, and the
  patched gateway every 15 seconds, until the API answers.
- With a database elsewhere, the API logs that it cannot enable
  `pg_stat_statements` unless the server preloads the library and grants the
  role `pg_read_all_settings`.
- `services.fluxer.s3.publicEndpoint` set to an IP address makes the app proxy
  log that the uploads bucket name is not DNS-compatible. The name is fine; the
  app proxy cannot build a virtual-host origin on an IP address.

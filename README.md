# fluxer-nix

Nix packaging for [Fluxer](https://fluxer.app): the desktop client, and NixOS
modules for running an instance. Each part of an instance is enabled
separately, so a host can run only the parts it needs.

The service packages and modules are new and not yet proven on a real
instance. See [Status](#status).

## Binary cache

CI builds every package for `x86_64-linux` and `aarch64-linux` and pushes them
to [Cachix](https://zekurio.cachix.org), so you can download them instead of
building them. The Rust services in particular take a long time to build.

```nix
{
  nix.settings = {
    extra-substituters = [ "https://zekurio.cachix.org" ];
    extra-trusted-public-keys = [ "zekurio.cachix.org-1:mv0mACvSLZtBkXXh5YDPPXmFBJ/eO+VkSzep6LJZrAg=" ];
  };
}
```

The cache only holds packages built with this flake's nixpkgs. The service
options default to those packages. You get cache misses if you set
`inputs.nixpkgs.follows` on this flake, or take the packages from the overlay,
since both build them with your nixpkgs.

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

A [daily workflow](#automatic-updates) runs this script too.

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
or `::`. The gateway's Erlang distribution port listens on loopback, unless
the gateway is in a cluster (below), and no epmd runs. The five internal
services talk to the rest over NATS. Each runs its router and shard in one
process.

On one host the API counts as started once it answers, so the services that
need it at startup, the gateway and push among them, start after that.

The services run as the `fluxer` user and group, which the module creates.
`services.fluxer.user` and `group` take others, which then have to exist,
such as a user of your own or one from a directory. With the local database
the user is also the database role.

The instance's units are part of `fluxer.target` and run in
`system-fluxer.slice`: the Fluxer services, and the backing services and
LiveKit when the module runs them. Stopping, starting or restarting the
target does that to all of them, for example around a backup or after a
secret changes:

```nix
services.restic.backups.fluxer = {
  backupPrepareCommand = "systemctl stop fluxer.target";
  backupCleanupCommand = "systemctl start fluxer.target";
};
sops.secrets.fluxer-sudo-mode.restartUnits = [ "fluxer.target" ];
```

`systemctl status system-fluxer.slice` shows them together with their memory
and CPU. PostgreSQL stays out of both, as other services on the host share
it. NATS, Meilisearch and LiveKit are the host's single instances too, so
their place in the target and slice is a default you can override.

The backing services each have `createLocally` (`seaweedfs.enable` for S3), on
with `services.fluxer.enable`, and an address for a server elsewhere:
`services.fluxer.postgres`, `valkey`, `nats`, `search` and `s3`.
`services.fluxer.endpoints` says where the services and the edge reach one
another when they run on different hosts.

The local backing services listen on
`services.fluxer.backingServices.listenAddress`, 127.0.0.1 by default. NATS
requires a token and Valkey a password, so other users on the host cannot use
them; both are generated with the other secrets. To share them with other
hosts, see [Several hosts](#several-hosts).

`services.fluxer.edge` is Caddy with upstream's routes. It also serves the
static assets directly, where upstream runs a second Caddy. To use another
reverse proxy, turn it off and copy the routes from `modules/edge.nix`.

### Several hosts

The host with the backing services shares them with the hosts listed in
`clients`:

```nix
services.fluxer.backingServices = {
  listenAddress = "10.0.0.1";   # this host, on the private network
  clients = [ "10.0.0.2" ];     # the hosts that use them
};
```

This opens their ports to those hosts only, and lets them into PostgreSQL
with the password in `FLUXER_POSTGRES_PASSWORD`. SeaweedFS shares only its S3
port. None of the backing services encrypt their traffic, so keep it on a
private network, such as the [tunnel](#tunnel). With a tunnel,
`listenAddress` defaults to its address.

A host that runs other parts, here the worker, points at them:

```nix
services.fluxer = {
  domain = "chat.example.com";
  worker.enable = true;
  postgres.host = "10.0.0.1";
  valkey = {
    url = "redis://10.0.0.1:6379/0";
    passwordFile = config.age.secrets.fluxer-valkey.path;
  };
  nats.url = "nats://10.0.0.1:4222";
  search.url = "http://10.0.0.1:7700";
  s3.endpoint = "http://10.0.0.1:8333";
  endpoints.api = "http://10.0.0.1:8080";
  secrets = { /* the same files as on the other hosts */ };
};
```

Every host needs the same secrets, so give them all as files. The worker
reads most of them, as the API does.

### Gateway cluster

Gateways on several hosts can form one cluster, as upstream's Helm chart runs
them. Upstream's Docker stack runs a single gateway. On each gateway host:

```nix
services.fluxer = {
  gateway.enable = true;
  # Every node needs the same cookie.
  secrets.FLUXER_ERLANG_COOKIE = config.age.secrets.fluxer-erlang-cookie.path;
  gateway.cluster = {
    enable = true;
    address = "10.0.0.2";                 # this host; defaults to the tunnel address
    peers = [ "10.0.0.2" "10.0.0.3" ];    # every gateway, this one included
    openFirewall = true;                  # port 9100, from the peers only
  };
};
```

The edge spreads clients over the gateways:

```nix
services.fluxer.endpoints.gateway = [ "http://10.0.0.2:8081" "http://10.0.0.3:8081" ];
```

Erlang distribution is not encrypted, and the cookie lets anyone who reaches
the port run code on every node. Keep the addresses on a private network, such
as the [tunnel](#tunnel). Upstream's Helm chart relies on the cluster network
the same way. With no epmd, every node uses the one distribution port,
`services.fluxer.gateway.distributionPort`.

`fluxer-gateway-ctl`, run as root on a gateway host, runs the release's own
commands against the running node, for example `fluxer-gateway-ctl ping` or
`fluxer-gateway-ctl rpc erlang nodes`.

### Tunnel

Nothing Fluxer's hosts send each other is encrypted, so it belongs on a
private network. `services.fluxer.tunnel` sets one up with WireGuard, or fits
the instance to one you already run.

The module's WireGuard tunnel takes the same list of hosts on every host, for
example from a file they all import:

```nix
services.fluxer.tunnel.wireguard = {
  enable = true;
  hosts = {
    main = {
      address = "10.77.0.1";
      publicKey = "…";                       # wg pubkey < its private key
      endpoint = "main.example.com:51820";   # where the others reach it
    };
    worker = {
      address = "10.77.0.2";
      publicKey = "…";                       # no endpoint: behind NAT
    };
  };
  privateKeyFile = config.sops.secrets.fluxer-wireguard.path;
};
```

Each host finds its own entry by `networking.hostName`, or by
`wireguard.name`, and connects to the others on the interface `wg-fluxer`,
UDP port 51820. A host without an endpoint connects to the ones with one and
keeps the connection open.

For a tunnel you already run, such as Tailscale, Nebula or Netbird, give its
address and interface:

```nix
services.fluxer.tunnel = {
  address = "100.64.0.1";
  interface = "tailscale0";
};
```

With either:

- The backing services, when shared with `clients`, and the gateway cluster
  listen on the tunnel address.
- The ports the module opens to other hosts open on the tunnel interface
  only, and there still only to the listed addresses.
- The services can start before the tunnel has its address. Most tunnels come
  up after them, so the module sets `net.ipv4.ip_nonlocal_bind`, which lets a
  service listen on an address the host does not have yet. The module's own
  WireGuard tunnel comes up before the services and needs this only under
  networkd.

The Fluxer services themselves listen on `services.fluxer.listenAddress`. For
other hosts to reach one, such as a gateway behind the edge on another host,
set it to `config.services.fluxer.tunnel.address` and open the port on the
tunnel: `networking.firewall.interfaces.wg-fluxer.allowedTCPPorts = [ 8081 ];`.

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
`FLUXER_S3_SECRET_ACCESS_KEY` the S3 key, `FLUXER_NATS_AUTH_TOKEN` the NATS
token, and `FLUXER_POSTGRES_PASSWORD` the password of a database elsewhere or
shared with other hosts. The Valkey password is
`services.fluxer.valkey.passwordFile`: Fluxer reads it only inside
`FLUXER_KV_URL`, which the module puts together at boot from
`services.fluxer.valkey.url`. The services on the database's own host need no
password: they run as the `fluxer` user and connect over the Unix socket. It also collects
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

### Automatic updates

`.github/workflows/update.yml` runs once a day and updates three pins
separately: the server release, `fluxer-desktop` and nixpkgs. Each pin that
changed is committed to its own branch (`update/fluxer`,
`update/fluxer-desktop`, `update/nixpkgs`), built and checked on both
architectures, and opened as a pull request. The pull request is a draft when CI
fails, with a link to the failing run. Merging it adds nothing new to build:
CI already pushed the packages to the cache.

The workflow skips a branch that already holds the same update. Delete the
branch to build it again.

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
- `multi-host`: an instance on two VMs, over the module's WireGuard tunnel.
  One shares its backing services and runs the API, a gateway and the edge;
  the other, with no endpoint as if behind NAT, runs the worker against those
  backing services, and a second gateway clustered with the first. It checks
  that the shared ports open on the tunnel only, that NATS and Valkey refuse
  clients without credentials, that SeaweedFS shares only S3, that the worker
  starts, that the gateways join, and that the edge keeps serving the gateway
  when one node stops.
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

Verified by the `multi-host` test: two hosts over the WireGuard tunnel, one
with the backing services, the API and a gateway, the other with the worker
and a second gateway in the same cluster.

Not verified yet: signing up and signing in, messages over the gateway, voice
calls, uploads through the media proxy, push notifications, and
`aarch64-linux`.

Known issues:

- The API and the worker still get most secrets, because upstream's
  configuration loader refuses to start without them, even ones they never use
  such as `FLUXER_ADMIN_SECRET_KEY_BASE`.
- The lists of secrets per service are read off upstream's source by hand. A
  release that makes a service read a new secret needs the list updated, or
  that service will not get it.
- The release's `ping` and `rpc` commands, which `fluxer-gateway-ctl` runs,
  pass the cookie on the command line of `erl_call` while they run.
- The multi-host test runs only the worker and a gateway away from the
  backing services. The API, the media proxy, push, the admin panel and the
  internal services take the same settings on another host, but no test runs
  them there.
- The multi-host test checks that the gateways join each other and that the
  edge keeps serving when one stops. It does not check that a session on one
  node reaches users on the other.
- Ordering push and the gateway after the API only works on one host.
  Elsewhere push fetches its configuration again every 30 seconds, and the
  patched gateway every 15 seconds, until the API answers.
- With a database elsewhere, the API logs that it cannot enable
  `pg_stat_statements` unless the server preloads the library and grants the
  role `pg_read_all_settings`.
- `services.fluxer.s3.publicEndpoint` set to an IP address makes the app proxy
  log that the uploads bucket name is not DNS-compatible. The name is fine; the
  app proxy cannot build a virtual-host origin on an IP address.

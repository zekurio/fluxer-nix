# Options shared by every Fluxer service on a host.
{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    literalExpression
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.fluxer;

  envValue = v: if lib.isBool v then lib.boolToString v else toString v;
  envName = types.strMatching "[A-Z][A-Z0-9_]*";
  settingsType = types.attrsOf (
    types.oneOf [
      types.str
      types.int
      types.bool
    ]
  );

  # The instance's units, on whichever host they run.
  instanceUnits = lib.filter (
    unit:
    unit.serviceConfig.Slice or null == "system-fluxer.slice" || lib.elem "fluxer.target" unit.partOf
  ) (lib.attrValues config.systemd.services);
in
{
  options.services.fluxer = {
    enable = lib.mkEnableOption ''
      a whole Fluxer instance on this host: every service, the backing
      services, the reverse proxy and generated secrets. Each part can still be
      turned off on its own'';

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "chat.example.com";
      description = ''
        The public hostname of the instance, in lowercase. Every host that runs a
        part of the instance needs the same value.
      '';
    };

    publicOrigin = mkOption {
      type = types.nullOr types.str;
      default = if cfg.domain == null then null else "https://${cfg.domain}";
      defaultText = literalExpression ''"https://''${config.services.fluxer.domain}"'';
      example = "https://chat.example.com:8443";
      description = "The origin browsers use to reach the instance, with no trailing slash.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        The address the Fluxer services listen on. The services on this host
        reach each other at it, or at loopback for a wildcard address.
      '';
    };

    localAddress = mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      description = "The host part of a URL that reaches a service on this host.";
    };

    user = mkOption {
      type = types.str;
      default = "fluxer";
      description = ''
        The user the Fluxer services run as. The module creates it under the
        default name; a user under another name has to exist already. With the
        local database it is also the database role, which the services reach
        over the Unix socket.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "fluxer";
      description = ''
        The group the Fluxer services run as. The module creates it under the
        default name; a group under another name has to exist already.
      '';
    };

    settings = mkOption {
      type = settingsType;
      default = { };
      example = {
        FLUXER_EMAIL_FROM_EMAIL = "noreply@example.com";
      };
      description = ''
        Settings for every Fluxer service on this host, as environment variables.
        The names are those on the configuration page of the operator docs.
        Settings derived from other options can be overridden here. Put secrets
        in {option}`services.fluxer.secrets` instead.
      '';
    };

    secrets = mkOption {
      type = types.attrsOf types.externalPath;
      default = { };
      example = literalExpression ''
        {
          FLUXER_SUDO_MODE_SECRET = config.age.secrets.fluxer-sudo-mode.path;
          FLUXER_GATEWAY_RPC_AUTH_TOKEN = config.sops.secrets.fluxer-gateway-rpc.path;
        }
      '';
      description = ''
        Files holding secret settings, keyed by variable name. A Fluxer service
        reads `FLUXER_<NAME>_FILE` in place of `FLUXER_<NAME>`, and systemd hands
        it the file as a credential, so the file can stay readable by root only.
        A trailing newline is ignored. Any secret manager that puts a file on
        the host works, such as agenix or sops-nix.

        A secret replaces the setting of the same name, so a default such as
        `FLUXER_KV_URL` can move here when it carries a password. Each service
        gets only the secrets it reads; those no service is known to read go
        to the API and the worker. To hand one to another service, set it in
        that service's `secrets` option as well.
      '';
    };

    generateSecrets = mkOption {
      type = types.bool;
      default = cfg.enable;
      defaultText = literalExpression "config.services.fluxer.enable";
      description = ''
        Generate every secret that {option}`services.fluxer.secrets` leaves out,
        once, into /var/lib/fluxer-secrets. Only for an instance on one host:
        hosts that share an instance need the same secrets, so give them the
        same files instead. Back the directory up, because data depends on some
        of these secrets.
      '';
    };

    generate = mkOption {
      type = types.attrsOf (
        types.enum [
          "hex32"
          "hex16"
          "base64-32"
          "rsa-der-base64"
          "vapid-public"
          "vapid-private"
        ]
      );
      default = { };
      internal = true;
      description = "Secrets the instance needs, and how to generate each.";
    };

    secretFiles = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      internal = true;
      description = "The secret files in use: the given ones, then the generated ones.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      internal = true;
      description = "The settings every Fluxer service on this host starts with.";
    };

    serviceEnv = mkOption {
      type = types.functionTo types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        Turns `{ settings, secrets, secretNames }` into the `environment` and
        `serviceConfig` of a systemd service: settings become environment
        variables, and each secret becomes a credential plus a `_FILE` variable
        pointing at it. A secret replaces the setting of the same name.
      '';
    };
  };

  config = {
    # The instance's units run in one slice, so their resources add up in one
    # place, and are part of one target, which starts, stops and restarts them
    # together, for a backup or a changed secret.
    systemd.slices.system-fluxer = lib.mkIf (instanceUnits != [ ]) {
      description = "Fluxer chat instance";
      documentation = [ "https://docs.fluxer.app/operator/" ];
    };
    systemd.targets.fluxer = lib.mkIf (instanceUnits != [ ]) {
      description = "Fluxer chat instance";
      documentation = [ "https://docs.fluxer.app/operator/" ];
      wantedBy = [ "multi-user.target" ];
    };

    assertions = [
      {
        assertion = lib.all (n: envName.check n) (lib.attrNames cfg.secrets ++ lib.attrNames cfg.settings);
        message = "services.fluxer.settings and services.fluxer.secrets take environment variable names, such as FLUXER_SUDO_MODE_SECRET.";
      }
      {
        assertion = cfg.enable -> cfg.domain != null;
        message = "services.fluxer.enable needs services.fluxer.domain.";
      }
    ];

    services.fluxer = {
      # Shared by the services; upstream's compose file and Helm chart derive
      # them from the public origin.
      settings = lib.mkIf (cfg.domain != null) (
        mapAttrs (_: lib.mkDefault) {
          FLUXER_ENV = "production";
          FLUXER_SELF_HOSTED = true;
          FLUXER_BASE_DOMAIN = cfg.domain;
          FLUXER_PUBLIC_ORIGIN = cfg.publicOrigin;
          FLUXER_APP_ENDPOINT = cfg.publicOrigin;
          FLUXER_MARKETING_ENDPOINT = cfg.publicOrigin;
          FLUXER_MEDIA_ENDPOINT = "${cfg.publicOrigin}/media";
          FLUXER_MEDIA_PROXY_PUBLIC_ENDPOINT = "${cfg.publicOrigin}/media";
          FLUXER_MEDIA_PROXY_UPLOAD_RELAY_ENDPOINT = "${cfg.publicOrigin}/media";
          FLUXER_GATEWAY_MEDIA_PROXY_ENDPOINT = "${cfg.publicOrigin}/media";
          FLUXER_GATEWAY_STATIC_CDN_ENDPOINT = cfg.publicOrigin;
          FLUXER_MEDIA_PROXY_CORS_ALLOWED_ORIGINS = cfg.publicOrigin;
          FLUXER_PASSKEY_RP_ID = cfg.domain;
          FLUXER_PASSKEY_ADDITIONAL_ALLOWED_ORIGINS = cfg.publicOrigin;
          FLUXER_EMAIL_FROM_EMAIL = "noreply@${cfg.domain}";
          FLUXER_VAPID_EMAIL = "admin@${cfg.domain}";
          FLUXER_API_PRESIGNED_HARVEST_DOWNLOADS_ENABLED = false;
        }
      );

      # The secrets of upstream's compose file. Infrastructure secrets are
      # added by the modules that set the infrastructure up.
      generate = {
        FLUXER_SUDO_MODE_SECRET = "hex32";
        FLUXER_CONNECTION_INITIATION_SECRET = "hex32";
        FLUXER_PROFILE_PSEUDONYM_SECRET = "hex32";
        FLUXER_GATEWAY_RPC_AUTH_TOKEN = "hex32";
        FLUXER_ERLANG_COOKIE = "hex32";
        FLUXER_MEDIA_PROXY_SECRET_KEY = "hex32";
        FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64 = "base64-32";
        FLUXER_ADMIN_SECRET_KEY_BASE = "hex32";
        FLUXER_ADMIN_OAUTH_CLIENT_SECRET = "hex32";
        FLUXER_SETUP_TOKEN = "hex16";
        FLUXER_ACTIVITYPUB_SIGNING_KEY_BASE64 = "rsa-der-base64";
        FLUXER_VAPID_PUBLIC_KEY = "vapid-public";
        FLUXER_VAPID_PRIVATE_KEY = "vapid-private";
      };

      secretFiles =
        lib.optionalAttrs cfg.generateSecrets (
          mapAttrs (name: _: "/var/lib/fluxer-secrets/${name}") cfg.generate
        )
        // cfg.secrets;

      environment = mapAttrs (_: envValue) (removeAttrs cfg.settings (lib.attrNames cfg.secretFiles));

      localAddress =
        {
          "0.0.0.0" = "127.0.0.1";
          "::" = "[::1]";
        }
        .${cfg.listenAddress}
          or (if lib.hasInfix ":" cfg.listenAddress then "[${cfg.listenAddress}]" else cfg.listenAddress);

      serviceEnv =
        {
          settings ? { },
          secrets ? { },
          # The shared secrets to pass, by name; null passes them all.
          secretNames ? null,
        }:
        let
          shared =
            if secretNames == null then
              cfg.secretFiles
            else
              lib.filterAttrs (name: _: lib.elem name secretNames) cfg.secretFiles;
          allSecrets = shared // secrets;
          # A shared secret replaces the setting for every service, even those
          # that do not get the secret.
          allSettings = removeAttrs (cfg.environment // settings) (lib.attrNames allSecrets);
        in
        {
          # systemd expands % specifiers in Environment=; only the credential
          # paths use one.
          environment =
            mapAttrs (_: v: lib.replaceStrings [ "%" ] [ "%%" ] (envValue v)) allSettings
            // mapAttrs' (name: _: nameValuePair "${name}_FILE" "%d/${name}") allSecrets;
          serviceConfig.LoadCredential = mapAttrsToList (name: path: "${name}:${path}") allSecrets;
        };
    };
  };
}

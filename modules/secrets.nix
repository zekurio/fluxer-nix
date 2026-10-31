# Generates the secrets of a single-host instance that the configuration does
# not supply, the way upstream's compose instructions do.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fluxer;
  dir = "/var/lib/fluxer-secrets";
  missing = removeAttrs cfg.generate (lib.attrNames cfg.secrets);

  openssl = lib.getExe pkgs.openssl;

  # Each recipe writes the secret to "$out".
  recipes = {
    hex32 = "${openssl} rand -hex 32 >\"$out\"";
    hex16 = "${openssl} rand -hex 16 >\"$out\"";
    base64-32 = "${openssl} rand -base64 32 >\"$out\"";
    rsa-der-base64 = ''
      ${openssl} genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -outform DER \
        | base64 -w0 >"$out"
    '';
    # The web push key pair, base64url without padding. Both halves come from
    # one key, generated when the private half is missing.
    vapid-private = ''
      ${openssl} ecparam -name prime256v1 -genkey -noout -out vapid.pem
      ${openssl} ec -in vapid.pem -outform DER 2>/dev/null | tail -c +8 | head -c 32 \
        | base64 | tr '/+' '_-' | tr -d '=\n' >"$out"
      ${openssl} ec -in vapid.pem -pubout -outform DER 2>/dev/null | tail -c 65 \
        | base64 | tr '/+' '_-' | tr -d '=\n' >FLUXER_VAPID_PUBLIC_KEY
      rm vapid.pem
    '';
    vapid-public = ":";
  };

  # The private VAPID key writes the public one too, so it goes first.
  order = lib.sort (a: b: a == "FLUXER_VAPID_PRIVATE_KEY" && b != a) (lib.attrNames missing);
in
{
  config = lib.mkIf (cfg.generateSecrets && missing != { }) {
    systemd.services.fluxer-secrets = {
      description = "Generate Fluxer secrets";
      wantedBy = [ "fluxer.target" ];
      partOf = [ "fluxer.target" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Slice = "system-fluxer.slice";
        StateDirectory = "fluxer-secrets";
        StateDirectoryMode = "0700";
        UMask = "0077";
        WorkingDirectory = dir;
      };
      script = lib.concatMapStrings (name: ''
        out=${name}
        if [ ! -s "$out" ]; then
          ${recipes.${missing.${name}}}
        fi
      '') order;
    };
  };
}

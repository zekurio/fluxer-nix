# Firewall rules that open TCP ports to some IPv4 addresses only, and on one
# interface only when given, for either of NixOS' firewall backends. Both run
# them before the final reject.
{ lib }:

{
  config,
  addresses,
  ports,
  interface ? null,
}:
let
  nftables = config.networking.nftables.enable;
in
lib.mkIf (addresses != [ ] && ports != [ ]) {
  extraInputRules = lib.mkIf nftables ''
    ${
      lib.optionalString (interface != null) "iifname \"${interface}\" "
    }ip saddr { ${lib.concatStringsSep ", " addresses} } tcp dport { ${
      lib.concatMapStringsSep ", " toString ports
    } } accept
  '';
  extraCommands = lib.mkIf (!nftables) (
    lib.concatMapStrings (
      address:
      lib.concatMapStrings (
        port:
        "iptables -A nixos-fw ${
          lib.optionalString (interface != null) "-i ${lib.escapeShellArg interface} "
        }-p tcp -s ${address} --dport ${toString port} -j nixos-fw-accept\n"
      ) ports
    ) addresses
  );
}

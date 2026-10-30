# Firewall rules that open TCP ports to some IPv4 addresses only, for either
# of NixOS' firewall backends. Both run them before the final reject.
{ lib }:

{
  config,
  addresses,
  ports,
}:
let
  nftables = config.networking.nftables.enable;
in
lib.mkIf (addresses != [ ] && ports != [ ]) {
  extraInputRules = lib.mkIf nftables ''
    ip saddr { ${lib.concatStringsSep ", " addresses} } tcp dport { ${
      lib.concatMapStringsSep ", " toString ports
    } } accept
  '';
  extraCommands = lib.mkIf (!nftables) (
    lib.concatMapStrings (
      address:
      lib.concatMapStrings (
        port: "iptables -A nixos-fw -p tcp -s ${address} --dport ${toString port} -j nixos-fw-accept\n"
      ) ports
    ) addresses
  );
}

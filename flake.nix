{
  description = "Fluxer desktop client and self-hosted services for Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: import ./pkgs { pkgs = final; };

      packages = forAllSystems (pkgs: import ./pkgs { inherit pkgs; });

      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ ./modules ];
          # The packages the service options default to, built with this
          # flake's nixpkgs.
          _module.args.fluxerPackages = self.packages.${pkgs.stdenv.hostPlatform.system};
        };

      checks = forAllSystems (
        pkgs:
        self.packages.${pkgs.stdenv.hostPlatform.system}
        // {
          eval = import ./tests/eval.nix {
            inherit lib pkgs;
            inherit (nixpkgs.lib) nixosSystem;
            module = self.nixosModules.default;
          };
          multi-host = import ./tests/multi-host.nix {
            inherit pkgs;
            module = self.nixosModules.default;
          };
          instance = import ./tests/instance.nix {
            inherit pkgs;
            module = self.nixosModules.default;
          };
          livekit = import ./tests/livekit.nix {
            inherit pkgs;
            module = self.nixosModules.default;
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}

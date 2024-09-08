{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs = inputs @ { nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem = { pkgs, ... }: {
        checks.interfaces = pkgs.testers.runNixOSTest ./tests/test.nix;
      };

      flake = {
        nixosModules = rec {
          vpnConfinement = ./modules/vpnnetns.nix;
          default = vpnConfinement;
        };
      };
    };
}

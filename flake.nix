{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
  };

  outputs = { nixpkgs, ... }: {
    nixosModules = rec {
      vpnconfinement = ./modules/vpnnetns.nix;
      default = vpnconfinement;
    };
  };
}

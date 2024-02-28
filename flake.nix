{
  description = "";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
  };

  outputs = { nixpkgs, ... }: {
    nixosModules = {
      vpnconfinement = ./modules/vpnnetns.nix;
    };
  };
}

{
  outputs = { nixpkgs, ... }: {
    nixosModules = rec {
      vpnconfinement = ./modules/vpnnetns.nix;
      default = vpnconfinement;
    };
  };
}

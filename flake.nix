{
  outputs = inputs:
  {
    nixosModules = rec {
      vpnConfinement = ./modules/vpn-netns.nix;
      default = vpnConfinement;
    };
  };
}

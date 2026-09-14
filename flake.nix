{
  outputs = inputs: {
    overlays.default = final: prev: {
      vpntunnel = prev.callPackage ./pkgs/vpn-tunnel.nix {};
    };

    nixosModules = rec {
      vpnConfinement = {
        imports = [./modules/vpn-netns.nix];
        nixpkgs.overlays = [inputs.self.overlays.default];
      };
      default = vpnConfinement;
    };
  };
}

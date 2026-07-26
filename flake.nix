{
  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";

  outputs = inputs: {
    overlays.default = final: prev: {
      vpntunnel = inputs.self.packages.${final.system}.default;
    };

    nixosModules = rec {
      vpnConfinement = {
        imports = [./modules/vpn-netns.nix];
        nixpkgs.overlays = [inputs.self.overlays.default];
      };
      default = vpnConfinement;
    };

    packages.x86_64-linux.default =
      inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/vpn-tunnel.nix {};
  };
}

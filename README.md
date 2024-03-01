# VPN-Confinement
A NixOS module which lets you route traffic from systemd services through a VPN while preventing DNS leaks.

# Installation

## Nix Flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    vpnconfinement.url = "github:Maroka-chan/VPN-Confinement";
    vpnconfinement.inputs.nixpkgs.follows "nixpkgs";
  };

  outputs = { self, nixpkgs, vpnconfinement, ... }: let
  in {
    # Change hostname, system, etc. as needed.
    nixosConfigurations.hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vpnconfinement.nixosModules.default
      ];
    };
  };
}

```

# Usage

## Example

```nix
# configuration.nix
{ pkgs, lib, config, ... }:
{
  # Define a VPN namespace.
  # vpnnamespaces.<name>
  vpnnamespaces.wg = {
    enable = true;
    accessibleFrom = [
      "192.168.0.0/24"
    ];
    wireguardConfigFile = /. + "/secrets/wg0.conf";
    portMappings = [
      { From = 8080; To = 80; }
      { From = 443; To = 443; }
    ];
  };

  # Enable and specify VPN namespace to confine service in.
  systemd.services.transmission.vpnconfinement = {
    enable = true;
    vpnnamespace = "wg";
  };

  services.transmission = {
    enable = true;
    settings = {
      "rpc-bind-address" = "192.168.15.1"; # Bind RPC/WebUI to bridge address
    };
  };
}
```

See all options and their descriptions in the [module file](https://github.com/Maroka-chan/VPN-Confinement/blob/a62ed5b97b1556c8c1eb2bc38bf384caab7234fc/modules/vpnnetns.nix#L88).

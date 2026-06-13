
<div align="right">
  <details>
    <summary >🌐 Language</summary>
    <div>
      <div align="center">
        <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=en">English</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=zh-CN">简体中文</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=zh-TW">繁體中文</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=ja">日本語</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=ko">한국어</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=hi">हिन्दी</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=th">ไทย</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=fr">Français</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=de">Deutsch</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=es">Español</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=it">Italiano</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=ru">Русский</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=pt">Português</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=nl">Nederlands</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=pl">Polski</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=ar">العربية</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=fa">فارسی</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=tr">Türkçe</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=vi">Tiếng Việt</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=id">Bahasa Indonesia</a>
        | <a href="https://openaitx.github.io/view.html?user=Maroka-chan&project=VPN-Confinement&lang=as">অসমীয়া</
      </div>
    </div>
  </details>
</div>



<div align="center" id="user-content-toc">
  <ul style="list-style: none;">
    <summary>
      <h1>⛓️ VPN-Confinement ⛓️</h1>
      <p>A NixOS module that lets you route traffic from systemd services through a VPN while preventing DNS leaks.</p>
    </summary>
  </ul>
</div>

<br />

> [!IMPORTANT]
> To "prevent" DNS leaks, this module simply makes the NSCD socket inaccessible to a systemd service. This might cause other problems, and leaks have only been tested when resolving DNS over UDP. Other ways of resolving DNS like DoT and DoH have not been tested, and DNS can leak in other ways, so you are always advised to monitor and test for DNS leaks yourself.

# Installation

## Nix Flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vpn-confinement.url = "github:Maroka-chan/VPN-Confinement";
  };

  outputs = { self, nixpkgs, vpn-confinement, ... }:
  {
    # Change hostname, system, etc. as needed
    nixosConfigurations.hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vpn-confinement.nixosModules.default
      ];
    };
  };
}

```

# Usage

## Define VPN network namespace

```nix
vpnNamespaces.<name> = { # The name is limited to 7 characters
  enable = true;
  wireguardConfigFile = <path to secret wireguard config file>;
  accessibleFrom = [
    "<ip or subnet>"
  ];
  portMappings = [{
      from = <port on host>;
      to = <port in VPN network namespace>;
      protocol = "<transport protocol>"; # protocol = "tcp"(default), "udp", or "both"
  }];
  openVPNPorts = [{
    port = <port to access through VPN interface>;
    protocol = "<transport protocol>"; # protocol = "tcp"(default), "udp", or "both"
  }];
};
```

## Add systemd service to VPN network namespace

```nix
systemd.services.<name>.vpnConfinement = {
  enable = true;
  vpnNamespace = "<network namespace name>";
};
```

## Example

```nix
# configuration.nix
{ pkgs, lib, config, ... }:
{
  # Define VPN network namespace
  vpnNamespaces.wg = {
    enable = true;
    wireguardConfigFile = /. + "/secrets/wg0.conf";
    accessibleFrom = [
      "192.168.0.0/24"
    ];
    portMappings = [
      { from = 9091; to = 9091; }
    ];
    openVPNPorts = [{
      port = 60729;
      protocol = "both";
    }];
  };

  # Add systemd service to VPN network namespace
  systemd.services.transmission.vpnConfinement = {
    enable = true;
    vpnNamespace = "wg";
  };

  services.transmission = {
    enable = true;
    settings = {
      "rpc-bind-address" = "192.168.15.1"; # Bind RPC/WebUI to VPN network namespace address

      # RPC-whitelist examples
      "rpc-whitelist" = "192.168.15.5"; # Access from default network namespace
      "rpc-whitelist" = "192.168.1.*";  # Access from other machines on specific subnet
      "rpc-whitelist" = "127.0.0.1";    # Access through loopback within VPN network namespace
    };
  };
}
```

> [!NOTE]
> Access from the default network namespace is done using the VPN network namespace address.\
> `curl 192.168.15.1:9091`

See all options and their descriptions in the [module file](modules/options.nix).

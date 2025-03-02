{
  name = "VPN-Confinement Tests";

  nodes = let
    base = {
      environment.etc = let
        config = ''
          [Interface]
          PrivateKey = 8PZQ8felOfsPGDaAPdHaJlkf0hcCn6JGhU1DJq5Ts3M=
          Address = 10.100.0.2/24
          DNS = 1.1.1.1

          [Peer]
          PublicKey = ObYLOQ9jBDhE2a/Jxgzg3f+Navp0rXjkctKCelb0xEI=
          AllowedIPs = 0.0.0.0/0
          Endpoint = 127.0.0.1:51820
        '';
      in {
        "wireguard/wg0.conf".text = config;
        "wireguard/wireguardconfiguration.txt".text = config;
      };
    };

    basicNetns = {
      vpnNamespaces.wg = {
        enable = true;
        accessibleFrom = [
          "192.168.0.0/24"
          "10.0.0.0/8"
          "127.0.0.1"
          "fd25:9ab6:6133::/64"
          "::"
        ];
        # Test unconventional name for config file
        wireguardConfigFile = "/etc/wireguard/wireguardconfiguration.txt";
        portMappings = [
          { from = 9091; to = 9091; }
        ];
        openVPNPorts = [{
          port = 60729;
          protocol = "both";
        }];
      };
    };

    createNode = config: { pkgs, lib, ... }: {
      imports = [ (import ../modules/vpn-netns.nix) ];
      config = lib.mkMerge (config ++ [ base ]);
    };
  in {
    machine_dhcp = createNode [ basicNetns ];

    machine_networkd = createNode [ basicNetns {
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.useDHCP = false;
      networking.dhcpcd.enable = false;
    }];

    machine_max_name_length = createNode [{
      vpnNamespaces.vpnname = {
        enable = true;
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
      };
    }];

    machine_dash_in_name = createNode [{
      vpnNamespaces.vpn-nam = {
        enable = true;
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
      };
    }];

    machine_arbitrary_config_name = createNode [{
      vpnNamespaces.vpn-nam = {
        enable = true;
        wireguardConfigFile = "/etc/wireguard/wireguardconfiguration.txt";
      };
    }];

    machine_resolved = createNode [ basicNetns {
      # services.resolved changes services.resolvconf.package
      # resulting in the resolvconf directory not being created.
      # Making the directory inaccessible fails if it does not exist,
      # so this test makes sure it does not fail when using resolved.

      services.resolved.enable = true;
      services.prowlarr.enable = true;

      systemd.services.prowlarr = {
        vpnConfinement.enable = true;
        vpnConfinement.vpnNamespace = "wg";
      };
    }];

    machine_no_namespaces = createNode [{
      # Tests that the module does not fail even when
      # no vpnnamespaces are defined.
    }];

    machine_ipv6_disabled = createNode [ basicNetns {
      networking.enableIPv6 = false;
    }];
  };

  testScript = ''
    start_all()

    machine_dhcp.wait_for_unit("wg.service")

    machine_dhcp.succeed('[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_dhcp.succeed(
      '[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_dhcp.succeed(
      '[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    machine_networkd.wait_for_unit("wg.service")

    machine_networkd.succeed(
      '[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_networkd.succeed(
      '[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_networkd.succeed(
      '[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    machine_max_name_length.wait_for_unit("vpnname.service")

    machine_max_name_length.succeed(
      '[ $(cat /sys/class/net/vpnname-br/operstate) == "up" ]')
    machine_max_name_length.succeed(
      '[ $(cat /sys/class/net/veth-vpnname-br/operstate) == "up" ]')
    machine_max_name_length.succeed(
      '[ $(ip netns exec vpnname \
        cat /sys/class/net/veth-vpnname/operstate) == "up" ]')

    machine_dash_in_name.wait_for_unit("vpn-nam.service")

    machine_dash_in_name.succeed(
      '[ $(cat /sys/class/net/vpn-nam-br/operstate) == "up" ]')
    machine_dash_in_name.succeed(
      '[ $(cat /sys/class/net/veth-vpn-nam-br/operstate) == "up" ]')
    machine_dash_in_name.succeed(
      '[ $(ip netns exec vpn-nam \
        cat /sys/class/net/veth-vpn-nam/operstate) == "up" ]')

    machine_resolved.wait_for_unit("wg.service")
    machine_resolved.wait_for_unit("prowlarr.service")

    machine_resolved.succeed(
      '[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_resolved.succeed(
      '[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_resolved.succeed(
      '[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    machine_ipv6_disabled.wait_for_unit("wg.service")
  '';
}

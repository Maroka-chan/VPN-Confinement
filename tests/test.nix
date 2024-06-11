{
  name = "VPN-Confinement Test";

  nodes = let
    base = {
      imports = [ (import ../modules/vpnnetns.nix) ];

      environment.etc = {
        "wireguard/wg0.conf".text = ''
          [Interface]
          PrivateKey = 8PZQ8felOfsPGDaAPdHaJlkf0hcCn6JGhU1DJq5Ts3M=
          Address = 10.100.0.2/24
          DNS = 1.1.1.1

          [Peer]
          PublicKey = ObYLOQ9jBDhE2a/Jxgzg3f+Navp0rXjkctKCelb0xEI=
          AllowedIPs = 0.0.0.0/0
          Endpoint = 127.0.0.1:51820
        '';
      };
    };
    basicNetns = {
      vpnnamespaces.wg = {
        enable = true;
        accessibleFrom = [
          "192.168.0.0/24"
          "10.0.0.0/8"
          "127.0.0.1"
        ];
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
        portMappings = [
          { from = 9091; to = 9091; }
        ];
        openVPNPorts = [{
          port = 60729;
          protocol = "both";
        }];
      };
    };
  in {
    machine_dhcp = { pkgs, ... }: base // basicNetns;
    machine_networkd = { pkgs, ... }: base // basicNetns // {
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.useDHCP = false;
      networking.dhcpcd.enable = false;
    };
    machine_max_name_length = { pkgs, ... }: base // {
      vpnnamespaces.vpnname = {
        enable = true;
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
      };
    };
    machine_dash_in_name = { pkgs, ... }: base // {
      vpnnamespaces.vpn-nam = {
        enable = true;
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
      };
    };
  };

  testScript = ''
    start_all()

    machine_dhcp.wait_for_unit("wg.service")

    machine_dhcp.succeed('[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_dhcp.succeed('[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_dhcp.succeed('[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    machine_networkd.wait_for_unit("wg.service")

    machine_networkd.succeed('[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_networkd.succeed('[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_networkd.succeed('[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    machine_max_name_length.wait_for_unit("vpnname.service")

    machine_max_name_length.succeed('[ $(cat /sys/class/net/vpnname-br/operstate) == "up" ]')
    machine_max_name_length.succeed('[ $(cat /sys/class/net/veth-vpnname-br/operstate) == "up" ]')
    machine_max_name_length.succeed('[ $(ip netns exec vpnname cat /sys/class/net/veth-vpnname/operstate) == "up" ]')

    machine_dash_in_name.wait_for_unit("vpn-nam.service")

    machine_dash_in_name.succeed('[ $(cat /sys/class/net/vpn-nam-br/operstate) == "up" ]')
    machine_dash_in_name.succeed('[ $(cat /sys/class/net/veth-vpn-nam-br/operstate) == "up" ]')
    machine_dash_in_name.succeed('[ $(ip netns exec vpn-nam cat /sys/class/net/veth-vpn-nam/operstate) == "up" ]')
  '';
}

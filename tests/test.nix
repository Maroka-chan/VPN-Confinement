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

      vpnnamespaces.wg = {
        enable = true;
        accessibleFrom = [
          "192.168.0.0/24"
        ];
        wireguardConfigFile = "/etc/wireguard/wg0.conf";
        portMappings = [
          { from = 9091; to = 9091; }
          { from = 3000; to = 3000; }
        ];
      };
    };
  in {
    machine_dhcp = { pkgs, ... }: base;
    machine_networkd = { pkgs, ... }: base // {
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.useDHCP = false;
      networking.dhcpcd.enable = false;
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
  '';
}

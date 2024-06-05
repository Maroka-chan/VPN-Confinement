{
  name = "VPN-Confinement Test";

  nodes.machine = { pkgs, ... }: {
    imports = [ (import ./modules/vpnnetns.nix) ];

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


    environment.etc = {
      "bruh".text = ''
        aa
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

  testScript = ''
    start_all()

    machine.wait_for_unit("wg.service")

    machine.succeed('[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine.succeed('[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine.succeed('[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')
  '';
}

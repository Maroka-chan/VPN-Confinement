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
        # 172.16.0.99 and fd25:9ab6:6134::99 are deliberately outside the
        # accessibleFrom subnets, so they prove allowedEgress installs its
        # own routes. 10.0.0.0/8 deliberately duplicates an accessibleFrom
        # entry, so it proves the overlap cannot fail the start script.
        allowedEgress = [
          "172.16.0.99"
          "fd25:9ab6:6134::99"
          "10.0.0.0/8"
          # the test driver numbers every machine as 192.168.1.x on the
          # shared vlan. fdc0:1::/64 is a static ULA assigned to eth1 on
          # two machines below. both back the end-to-end LAN egress pings.
          "192.168.1.0/24"
          "fdc0:1::/64"
          # Including the bridge addresses (default values) to prove
          # they do not produce self-referential routes that poison
          # other resolutions, but also allow for routing back to the host.
          "192.168.15.5"
          "fd93:9701:1d00::1"
        ];
        # Test unconventional name for config file
        wireguardConfigFile = "/etc/wireguard/wireguardconfiguration.txt";
        portMappings = [
          {
            from = 9091;
            to = 9091;
          }
        ];
        openVPNPorts = [
          {
            port = 60729;
            protocol = "both";
          }
        ];
      };
    };

    createNode = config: {
      pkgs,
      lib,
      ...
    }: {
      imports = [(import ../modules/vpn-netns.nix)];
      config = lib.mkMerge (config ++ [base]);
    };
  in {
    machine_dhcp = createNode [
      basicNetns
      {
        # static ULA on the test vlan, used as the masquerade source for
        # the v6 LAN egress ping
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = "fdc0:1::3";
            prefixLength = 64;
          }
        ];
      }
    ];

    machine_networkd = createNode [
      basicNetns
      {
        networking.useNetworkd = true;
        systemd.network.enable = true;
        networking.useDHCP = false;
        networking.dhcpcd.enable = false;

        # target of the v6 LAN egress ping
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = "fdc0:1::6";
            prefixLength = 64;
          }
        ];
      }
    ];

    machine_max_name_length = createNode [
      {
        vpnNamespaces.vpnname = {
          enable = true;
          wireguardConfigFile = "/etc/wireguard/wg0.conf";
        };
      }
    ];

    machine_dash_in_name = createNode [
      {
        vpnNamespaces.vpn-nam = {
          enable = true;
          wireguardConfigFile = "/etc/wireguard/wg0.conf";
        };
      }
    ];

    machine_arbitrary_config_name = createNode [
      {
        vpnNamespaces.vpn-nam = {
          enable = true;
          wireguardConfigFile = "/etc/wireguard/wireguardconfiguration.txt";
        };
      }
    ];

    machine_resolved = createNode [
      basicNetns
      {
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
      }
    ];

    machine_no_namespaces = createNode [
      {
        # Tests that the module does not fail even when
        # no vpnnamespaces are defined.
      }
    ];

    machine_ipv6_disabled = createNode [
      basicNetns
      {
        networking.enableIPv6 = false;
      }
    ];
  };

  testScript = ''
    start_all()

    machine_dhcp.wait_for_unit("wg.service")

    machine_dhcp.succeed('[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_dhcp.succeed(
      '[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_dhcp.succeed(
      '[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    # allowedEgress installs a route via the bridge and an accept that
    # precedes the veth NEW drop, for v4 and v6
    machine_dhcp.succeed(
      'ip netns exec wg ip route get 172.16.0.99 | grep -q "via 192.168.15.5"')
    machine_dhcp.succeed(
      'ip netns exec wg ip route get fd25:9ab6:6134::99 | grep -q "via fd93:9701:1d00::1"')

    # Bridge addresses should not exist in the routing table, they are
    # inherently reachable via veth. A self-referential ipv6 route would prevent
    # other ipv6 routes from being routable.
    machine_dhcp.fail(
      'ip netns exec wg ip -6 route show fd93:9701:1d00::1 | grep -q "fd93:9701:1d00::1 via fd93:9701:1d00::1"')
    machine_dhcp.fail(
      'ip netns exec wg ip route show 192.168.15.5 | grep -q "192.168.15.5 via 192.168.15.5"')

    egress_rules = machine_dhcp.succeed("ip netns exec wg iptables -S OUTPUT")
    assert egress_rules.index("-d 172.16.0.99/32") < egress_rules.index("--ctstate NEW -j DROP")

    egress_rules_v6 = machine_dhcp.succeed("ip netns exec wg ip6tables -S OUTPUT")
    assert egress_rules_v6.index("-d fd25:9ab6:6134::99/128") < egress_rules_v6.index("--ctstate NEW -j DROP")

    # allowedEgress masquerades namespace traffic on the host, so LAN
    # machines beyond the host can route replies back
    machine_dhcp.succeed(
      "iptables -t nat -S wg-postrouting | grep -q -- '-d 172.16.0.99/32.*-j MASQUERADE'")
    machine_dhcp.succeed(
      "ip6tables -t nat -S wg-postrouting | grep -q -- '-d fd25:9ab6:6134::99/128.*-j MASQUERADE'")

    machine_networkd.wait_for_unit("wg.service")

    machine_networkd.succeed(
      '[ $(cat /sys/class/net/wg-br/operstate) == "up" ]')
    machine_networkd.succeed(
      '[ $(cat /sys/class/net/veth-wg-br/operstate) == "up" ]')
    machine_networkd.succeed(
      '[ $(ip netns exec wg cat /sys/class/net/veth-wg/operstate) == "up" ]')

    # LAN egress, end to end: reach another machine on the test vlan from
    # inside the netns. The peer has no route back to the namespace
    # subnet, so replies only arrive if the host forwarded and
    # masqueraded the traffic.
    peer_v4 = machine_networkd.succeed(
      "ip -4 -o addr show eth1 scope global | awk 'NR==1 {print $4}' | cut -d/ -f1"
    ).strip()
    machine_dhcp.wait_until_succeeds(
      f"ip netns exec wg ping -c 1 -W 2 {peer_v4}", timeout=60)
    machine_dhcp.wait_until_succeeds(
      "ip netns exec wg ping -c 1 -W 2 fdc0:1::6", timeout=60)

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

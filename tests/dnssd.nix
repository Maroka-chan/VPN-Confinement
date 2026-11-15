{lib, ...}: let
  # Runs a web server inside the VPN namespace and announces it over mDNS
  server = extra: {
    pkgs,
    lib,
    ...
  }: {
    imports = [(import ../modules/vpn-netns.nix) extra];

    environment.etc."wireguard/wg0.conf".text = ''
      [Interface]
      PrivateKey = 8PZQ8felOfsPGDaAPdHaJlkf0hcCn6JGhU1DJq5Ts3M=
      Address = 10.100.0.2/24
      DNS = 1.1.1.1

      [Peer]
      PublicKey = ObYLOQ9jBDhE2a/Jxgzg3f+Navp0rXjkctKCelb0xEI=
      AllowedIPs = 0.0.0.0/0
      Endpoint = 127.0.0.1:51820
    '';
    environment.etc."web/index.html".text = "hello from the namespace";

    services.resolved.enable = true;

    vpnNamespaces.wg = {
      enable = true;
      wireguardConfigFile = "/etc/wireguard/wg0.conf";
      # The test driver puts every machine on 192.168.1.0/24
      allowedIngress = ["192.168.1.0/24"];
      portMappings = [3000];
      dnssd = [
        {
          name = "Web on %H";
          type = "_testweb._tcp";
          port = 3000;
          txt = ["path=/"];
        }
      ];
    };

    systemd.services.web = {
      wantedBy = ["multi-user.target"];
      vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 3000 --directory /etc/web";
    };
  };
in {
  name = "VPN-Confinement DNS-SD";

  nodes = {
    # Scripted networking: nothing sets mDNS per link, so resolved uses its
    # global setting there
    server = server {};

    # NetworkManager sets mDNS per link from connection.mdns, which defaults to
    # "no"; the module makes it "yes" for connections that don't set it
    servernm = server ({
      config,
      lib,
      ...
    }: {
      # Let NetworkManager manage the test network's interface from boot,
      # instead of the test driver's scripted address configuration
      systemd.services."network-addresses-eth1".enable = lib.mkForce false;

      networking.networkmanager = {
        enable = true;
        ensureProfiles.profiles.lan = {
          connection = {
            id = "lan";
            type = "ethernet";
            interface-name = "eth1";
          };
          ipv4 = {
            method = "manual";
            address1 = "${config.networking.primaryIPAddress}/24";
          };
          ipv6.method = "disabled";
        };
      };
    });

    # A LAN client looking for the services, like a TV or phone app would
    client = {pkgs, ...}: {
      services.avahi = {
        enable = true;
        openFirewall = true;
      };
      environment.systemPackages = [pkgs.avahi pkgs.curl];
    };
  };

  testScript = ''
    def ip_of(machine):
        return machine.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()

    def find_announcement(name):
        """Fields of the resolved IPv4 announcement with this instance name"""
        # =;iface;protocol;name;type;domain;hostname;address;port;txt
        # avahi-browse escapes spaces as \032
        escaped = name.replace(" ", "\\032")

        import time
        deadline = time.monotonic() + 120
        while True:
            out = client.succeed("avahi-browse --resolve --parsable --terminate _testweb._tcp")
            for line in out.splitlines():
                fields = line.split(";")
                if fields[0] == "=" and fields[2] == "IPv4" and fields[3] == escaped:
                    return fields
            assert time.monotonic() < deadline, f"no announcement named {name!r}:\n{out}"
            time.sleep(2)

    start_all()
    client.wait_for_unit("avahi-daemon.service")

    for machine in [server, servernm]:
        machine.wait_for_unit("systemd-resolved.service")
        machine.wait_for_unit("wg.service")
        machine.wait_for_unit("web.service")
        machine.wait_for_open_port(3000, "192.168.15.1")

    with subtest("without a network manager, the LAN link uses resolved's global mDNS setting"):
        server.succeed("resolvectl mdns eth1 | grep -E ': yes$'")

    with subtest("NetworkManager connections get mDNS enabled by default"):
        servernm.wait_until_succeeds("nmcli -t -f GENERAL.STATE connection show lan | grep activated", timeout=60)
        servernm.succeed("grep -x 'connection.mdns=2' /etc/NetworkManager/NetworkManager.conf")
        # NetworkManager passed the connection's mDNS setting on to resolved
        servernm.wait_until_succeeds("resolvectl mdns eth1 | grep -E ': yes$'", timeout=60)

    # Forget anything announced while the servers were starting, so only
    # current answers count
    client.succeed("systemctl restart avahi-daemon.service")
    client.wait_for_unit("avahi-daemon.service")

    for machine in [server, servernm]:
        with subtest(f"{machine.name}: announced with the host's address and mapped port"):
            fields = find_announcement(f"Web on {machine.name}")
            address, port, txt = fields[7], fields[8], fields[9]
            assert address == ip_of(machine), f"announced {address}, host is {ip_of(machine)}: {fields}"
            assert port == "3000", fields
            assert '"path=/"' in txt, fields

        with subtest(f"{machine.name}: the announced address reaches the service in the namespace"):
            client.succeed(f"curl -sf http://{address}:{port}/ | grep 'hello from the namespace'")

        with subtest(f"{machine.name}: nothing in the namespace sends mDNS"):
            # The kill switch still drops new outgoing veth traffic; the host announces
            machine.fail("ip netns exec wg ss -ulpn | grep ':5353 '")
  '';
}

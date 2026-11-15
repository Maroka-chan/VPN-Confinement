{lib, ...}: {
  name = "VPN-Confinement DNS-SD";

  nodes = {
    # Runs a web server inside the VPN namespace and announces it over mDNS
    server = {pkgs, ...}: {
      imports = [(import ../modules/vpn-netns.nix)];

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

    # A LAN client looking for the service, like a TV or phone app would
    client = {pkgs, ...}: {
      services.avahi = {
        enable = true;
        openFirewall = true;
      };
      environment.systemPackages = [pkgs.avahi pkgs.curl];
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("systemd-resolved.service")
    server.wait_for_unit("wg.service")
    server.wait_for_unit("web.service")
    server.wait_for_open_port(3000, "192.168.15.1")

    # The dnssd option enables mDNS in resolved globally; it must also be on
    # for the LAN link, which on real hosts is NetworkManager's connection.mdns
    server.succeed("resolvectl mdns eth1 yes")
    server_ip = server.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()

    with subtest("the service is announced with the host's address and mapped port"):
        client.wait_for_unit("avahi-daemon.service")
        # =;iface;protocol;name;type;domain;hostname;address;port;txt
        line = client.wait_until_succeeds(
            "avahi-browse --resolve --parsable --terminate _testweb._tcp | grep '^=.*;IPv4;'",
            timeout=120,
        ).splitlines()[0]
        fields = line.split(";")
        name, address, port, txt = fields[3], fields[7], fields[8], fields[9]
        # avahi-browse escapes spaces as \032
        assert name == "Web\\032on\\032server", line
        assert address == server_ip, f"announced {address}, server is {server_ip}: {line}"
        assert port == "3000", line
        assert '"path=/"' in txt, line

    with subtest("the announced address and port reach the service in the namespace"):
        client.succeed(f"curl -sf http://{address}:{port}/ | grep 'hello from the namespace'")

    with subtest("nothing in the namespace sends mDNS"):
        # The kill switch still drops new outgoing veth traffic; the host announces
        server.fail("ip netns exec wg ss -ulpn | grep ':5353 '")
  '';
}

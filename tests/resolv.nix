{lib, ...}: {
  name = "VPN-Confinement resolv.conf";

  # Confined services must keep using the VPN's DNS (the namespace's
  # resolv.conf) for as long as they run. With systemd-resolved, /etc/resolv.conf
  # is a symlink to a file that resolved replaces whenever DNS settings change,
  # which used to undo the bind mount of the VPN's resolv.conf.
  nodes.machine = {pkgs, ...}: {
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

    services.resolved.enable = true;

    vpnNamespaces.wg = {
      enable = true;
      wireguardConfigFile = "/etc/wireguard/wg0.conf";
    };

    systemd.services.confined = {
      wantedBy = ["multi-user.target"];
      vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
  };

  testScript = ''
    def service_resolv_conf():
        pid = machine.succeed("systemctl show -p MainPID --value confined.service").strip()
        return machine.succeed(f"nsenter -t {pid} -m cat /etc/resolv.conf")

    machine.wait_for_unit("systemd-resolved.service")
    machine.wait_for_unit("confined.service")
    print(machine.succeed("ls -l /etc/resolv.conf; readlink -f /etc/resolv.conf"))

    with subtest("a confined service uses the VPN's DNS"):
        resolv = service_resolv_conf()
        assert "nameserver 1.1.1.1" in resolv, resolv
        assert "127.0.0.53" not in resolv, resolv

    with subtest("it still does after resolved rewrites its stub resolv.conf"):
        # Changing DNS settings makes resolved replace stub-resolv.conf
        machine.succeed("resolvectl domain eth1 example.test")
        machine.wait_until_succeeds("grep example.test /run/systemd/resolve/stub-resolv.conf")
        machine.succeed("systemctl restart systemd-resolved.service")
        machine.wait_for_unit("systemd-resolved.service")

        resolv = service_resolv_conf()
        assert "nameserver 1.1.1.1" in resolv, resolv
        assert "127.0.0.53" not in resolv, resolv

    with subtest("resolved's socket isn't reachable from confined services"):
        pid = machine.succeed("systemctl show -p MainPID --value confined.service").strip()
        machine.fail(f"nsenter -t {pid} -m test -e /run/systemd/resolve/io.systemd.Resolve")
  '';
}

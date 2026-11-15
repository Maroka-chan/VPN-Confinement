{
  lib,
  config,
  name,
  ...
}: let
  inherit (import ../lib/types.nix {inherit lib;}) ipAddress ipv4 ipv6;
  inherit (lib) mkEnableOption mkOption;
  inherit
    (lib.types)
    listOf
    submodule
    coercedTo
    path
    port
    enum
    str
    ;

  portsFor = proto:
    map (p: p.port)
    (lib.filter (p: p.protocol == proto || p.protocol == "both") config.openVPNPorts);
in {
  imports = [(lib.mkRenamedOptionModule ["accessibleFrom"] ["allowedIngress"])];

  options = {
    # Collected by vpn-netns.nix into the top-level `warnings`.
    # Declaring it here also lets mkRenamedOptionModule emit its warning.
    warnings = mkOption {
      type = listOf str;
      default = [];
      internal = true;
      visible = false;
    };

    enable =
      mkEnableOption "vpn netns"
      // {
        description = ''
          Whether to enable the VPN namespace.

          To access the networking namespace(netns) a veth pair
          is created to connect it and the default namespace
          through a linux bridge. One end of the pair is
          connected to the linux bridge on the default netns.
          The other end is connected to the vpn netns.
        '';
      };

    allowedIngress = mkOption {
      type = listOf ipAddress;
      default = [];
      description = ''
        Subnets, ranges, and specific addresses that the
        namespace should be accessible to.
      '';
      example = [
        "10.0.2.0/24"
        "192.168.1.27"
        "fd25:9ab6:6133::/64"
        "fd25:9ab6:6133::203"
      ];
    };

    allowedEgress = mkOption {
      type = listOf ipAddress;
      default = [];
      description = ''
        Subnets, ranges, and specific addresses that the
        namespace may initiate connections to outside the
        VPN tunnel, e.g. a database or media server on the
        host or LAN.

        Traffic to these destinations is routed over the
        veth pair instead of the tunnel, and is exempt from
        the kill switch that drops new outgoing connections
        via the veth. All other outgoing traffic still only
        leaves through the tunnel.
      '';
      example = [
        "10.0.2.15"
        "192.168.1.0/24"
        "fd25:9ab6:6133::203"
      ];
    };

    namespaceAddress = mkOption {
      type = ipv4;
      default = "192.168.15.1";
      description = ''
        The address of the veth interface connected to the vpn namespace.

        This is the address used to reach the vpn namespace from other
        namespaces connected to the linux bridge.
      '';
    };

    namespaceAddressIPv6 = mkOption {
      type = ipv6;
      default = "fd93:9701:1d00::2";
      description = ''
        The address of the veth interface connected to the vpn namespace.

        This is the address used to reach the vpn namespace from other
        namespaces connected to the linux bridge.
      '';
    };

    bridgeAddress = mkOption {
      type = ipv4;
      default = "192.168.15.5";
      description = ''
        The address of the linux bridge on the default namespace.

        The linux bridge sits on the default namespace and
        needs an address to make communication between connected
        namespaces possible, including the default namespace.
      '';
    };

    bridgeAddressIPv6 = mkOption {
      type = ipv6;
      default = "fd93:9701:1d00::1";
      description = ''
        The address of the linux bridge on the default namespace.

        The linux bridge sits on the default namespace and
        needs an address to make communication between connected
        namespaces possible, including the default namespace.
      '';
    };

    vpn = {
      allowedTCPPorts = mkOption {
        type = listOf port;
        default = [];
        description = ''
          TCP ports to allow inbound on the VPN interface.
        '';
      };

      allowedUDPPorts = mkOption {
        type = listOf port;
        default = [];
        description = ''
          UDP ports to allow inbound on the VPN interface.
        '';
      };
    };

    openVPNPorts = mkOption {
      type = listOf (submodule {
        options = {
          port = mkOption {
            type = port;
            description = "The port to open.";
          };
          protocol = mkOption {
            default = "tcp";
            example = "both";
            type = enum [
              "tcp"
              "udp"
              "both"
            ];
            description = "The transport layer protocol to use.";
          };
        };
      });
      default = [];
      visible = false;
      description = "Deprecated: use vpn.allowedTCPPorts and vpn.allowedUDPPorts.";
    };

    portMappings = mkOption {
      type = listOf (coercedTo port (p: {
          from = p;
          to = p;
        })
        (submodule {
          options = {
            from = mkOption {
              example = 80;
              type = port;
              description = "Port on the default netns.";
            };
            to = mkOption {
              example = 443;
              type = port;
              description = "Port on the VPN netns.";
            };
            protocol = mkOption {
              default = "tcp";
              example = "both";
              type = enum [
                "tcp"
                "udp"
                "both"
              ];
              description = "The transport layer protocol to use.";
            };
          };
        }));
      default = [];
      description = ''
        A list of port mappings from
        the host to ports in the namespace.
        Neither the 'to' or 'from' ports should
        be open on the default netns as they are
        routed to the VPN netns.
        The 'to' ports are automatically opened
        in the VPN netns.
      '';
      example = [
        80 # coerced to the form below
        {
          from = 80;
          to = 80;
          protocol = "tcp";
        }
      ];
    };

    dnssd = mkOption {
      type = listOf (submodule {
        options = {
          name = mkOption {
            type = str;
            example = "My service on %H";
            description = ''
              Instance name shown to clients browsing the network.
              Supports systemd.dnssd(5) specifiers, e.g. `%H` for the
              host name.
            '';
          };
          type = mkOption {
            type = lib.types.strMatching "_[A-Za-z0-9-]+\\._(tcp|udp)";
            example = "_http._tcp";
            description = ''
              DNS-SD service type, e.g. `_http._tcp`.
              The protocol suffix decides which port mappings
              {option}`port` can refer to.
            '';
          };
          port = mkOption {
            type = port;
            example = 8080;
            description = ''
              Port to announce. Must be the host side (`from`) of one
              of the namespace's {option}`portMappings`, as that is
              where clients on the LAN can reach the service.
            '';
          };
          txt = mkOption {
            type = listOf (lib.types.strMatching "[^ =]+(=[^ ]*)?");
            default = [];
            example = ["path=/" "version=1"];
            description = ''
              TXT record entries, as `key=value` without spaces.
            '';
          };
        };
      });
      default = [];
      description = ''
        DNS-SD services to announce over mDNS on behalf of the namespace,
        so clients on the LAN can discover them.

        Services in the namespace can't announce themselves: mDNS is
        link-local multicast and doesn't cross from the namespace's bridge
        to the LAN, the kill switch drops new outgoing traffic on the veth,
        and the namespace's own address isn't reachable from the LAN anyway.
        Instead the host announces them with its own address and the mapped
        port, using systemd-resolved, so nothing leaves the namespace.

        Requires systemd-resolved, and mDNS must be enabled on the LAN link:
        with NetworkManager, set `connection.mdns` to `2` (yes), e.g. via
        `networking.networkmanager.settings.connection."connection.mdns" = 2;`.
      '';
      example = [
        {
          name = "Transmission on %H";
          type = "_http._tcp";
          port = 9091;
          txt = ["path=/transmission/web/"];
        }
      ];
    };

    wireguardConfigFile = mkOption {
      type = path;
      default = null;
      example = "/secret/wg0.conf";
      description = ''
        Path to a wg-quick config file.
      '';
    };
  };

  config = {
    warnings = lib.optional (config.openVPNPorts != []) ''
      vpnNamespaces.${name}.openVPNPorts is deprecated and will be removed.
      Use vpnNamespaces.${name}.vpn.allowedTCPPorts and
      vpnNamespaces.${name}.vpn.allowedUDPPorts instead.
    '';

    vpn.allowedTCPPorts = portsFor "tcp";
    vpn.allowedUDPPorts = portsFor "udp";
  };
}

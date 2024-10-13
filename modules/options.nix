{ lib, ... }:
let
  inherit (import ../lib/types.nix { inherit lib; }) ipAddress ipv4 ipv6;
  inherit (lib) mkEnableOption mkOption;
  inherit (lib.types) listOf submodule path port enum;
in {
  options = {
    enable = mkEnableOption ("vpn netns") // {
      description = ''
        Whether to enable the VPN namespace.

        To access the networking namespace(netns) a veth pair
        is created to connect it and the default namespace
        through a linux bridge. One end of the pair is
        connected to the linux bridge on the default netns.
        The other end is connected to the vpn netns.
      '';
    };

    accessibleFrom = mkOption {
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
            type = enum [ "tcp" "udp" "both" ];
            description = "The transport layer protocol to open the ports for.";
          };
        };
      });
      default = [];
      description = ''
        Ports that should be accessible through the VPN interface.
      '';
    };

    portMappings = mkOption {
      type = listOf (submodule {
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
            type = enum [ "tcp" "udp" "both" ];
            description = "The transport layer protocol to open the ports for.";
          };
        };
      });
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
      example = [{
        from = 80;
        to = 80;
        protocol = "tcp";
      }];
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
}

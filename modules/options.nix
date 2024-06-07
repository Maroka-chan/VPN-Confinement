{ lib, ... }:
with lib;
{
  options = {
    enable = mkEnableOption (mdDoc "vpn netns") // {
      description = mdDoc ''
        Whether to enable the VPN namespace.

        To access the networking namespace(netns) a veth pair
        is created to connect it and the default namespace
        through a linux bridge. One end of the pair is
        connected to the linux bridge on the default netns.
        The other end is connected to the vpn netns.
      '';
    };

    accessibleFrom = mkOption {
      type = types.listOf types.str;
      default = [];
      description = mdDoc ''
        Subnets or specific addresses that the
        namespace should be accessible to.
      '';
      example = [
        "10.0.2.0/24"
        "192.168.1.27"
      ];
    };

    namespaceAddress = mkOption {
      type = types.str;
      default = "192.168.15.1";
      description = mdDoc ''
        The address of the veth interface connected to the vpn namespace.

        This is the address used to reach the vpn namespace from other
        namespaces connected to the linux bridge.
      '';
    };

    bridgeAddress = mkOption {
      type = types.str;
      default = "192.168.15.5";
      description = mdDoc ''
        The address of the linux bridge on the default namespace.

        The linux bridge sits on the default namespace and
        needs an address to make communication between connected
        namespaces possible, including the default namespace.
      '';
    };

    openVPNPorts = mkOption {
      type = with types; listOf (submodule {
        options = {
          port = mkOption {
            type = port;
            description = lib.mdDoc "The port to open.";
          };
          protocol = mkOption {
            default = "tcp";
            example = "both";
            type = types.enum [ "tcp" "udp" "both" ];
            description = lib.mdDoc "The transport layer protocol to open the ports for.";
          };
        };
      });
      default = [];
      description = ''
        Ports that should be accessible through the VPN interface.
      '';
    };

    portMappings = mkOption {
      type = with types; listOf (submodule {
        options = {
          from = mkOption {
            example = 80;
            type = port;
            description = lib.mdDoc "Port on the default netns.";
          };
          to = mkOption {
            example = 443;
            type = port;
            description = lib.mdDoc "Port on the VPN netns.";
          };
          protocol = mkOption {
            default = "tcp";
            example = "both";
            type = types.enum [ "tcp" "udp" "both" ];
            description = lib.mdDoc "The transport layer protocol to open the ports for.";
          };
        };
      });
      default = [];
      description = mdDoc ''
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
      type = types.path;
      default = null;
      example = "/secret/wg0.conf";
      description = mdDoc ''
        Path to a wg-quick config file.
      '';
    };
  };
}

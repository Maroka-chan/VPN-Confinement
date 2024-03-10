{ lib, pkgs, config, ... }:
with lib;
let
  namespaceToService = name: def: {
    description = "${name} network interface";
    bindsTo = [ "netns@${name}.service" ];
    requires = [ "network-online.target" ];
    after = [ "netns@${name}.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = let vpnUp = pkgs.writeShellApplication {
        name = "${name}-up";

        runtimeInputs = with pkgs; [ iproute2 wireguard-tools iptables bash ];

        text = ''
          TMPDIR=$(mktemp -d)
          cp ${def.wireguardConfigFile} > "$TMPDIR/${name}.conf"

          # Set up the wireguard interface
          ip netns add ${name}
          ip link add ${name}0 type wireguard
          ip link set ${name}0 netns ${name}

          # Parse wireguard INI config file
          # shellcheck disable=SC1090
          source <(grep -e "DNS" -e "Address" "$TMPDIR/${name}.conf" | tr -d ' ')

          # Add DNS
          mkdir -p /etc/netns/${name}
          echo "nameserver $DNS" > /etc/netns/${name}/resolv.conf

          # Add Addresses
          IFS=","
          # shellcheck disable=SC2154
          for addr in $Address; do
              ip -n ${name} address add "$addr" dev ${name}0
          done

          # Set wireguard config
          ip netns exec ${name} \
            wg setconf ${name}0 <(wg-quick strip "$TMPDIR/${name}.conf")

          ip -n ${name} link set ${name}0 up
          ip -n ${name} route add default dev ${name}0

          # Start the loopback interface
          ip -n ${name} link set dev lo up

          # Create a bridge
          ip link add ${name}-br type bridge
          ip addr add ${def.bridgeAddress}/24 dev ${name}-br
          ip link set dev ${name}-br up

          # Set up veth pair to link namespace with host network
          ip link add veth-${name}-br type veth peer name veth-${name} netns ${name}
          ip link set veth-${name}-br master ${name}-br

          ip -n ${name} addr add ${def.namespaceAddress}/24 dev veth-${name}
          ip -n ${name} link set dev veth-${name} up
        ''
        # Add routes to make the namespace accessible
        + strings.concatMapStrings (x: "ip -n ${name} route add ${x} via ${def.bridgeAddress}" + "\n") def.accessibleFrom
        # Add prerouting rules
        + strings.concatMapStrings (x: "iptables -t nat -A PREROUTING -p tcp --dport ${builtins.toString x.From} -j DNAT --to-destination ${def.namespaceAddress}:${builtins.toString x.To}" + "\n") def.portMappings;
      }; in "${vpnUp}/bin/${name}-up";

      ExecStopPost = let vpnDown = pkgs.writeShellApplication {
        name = "${name}-down";

        runtimeInputs = with pkgs; [ iproute2 iptables ];

        text = ''
          ip netns del ${name}
          ip link del ${name}-br
          ip link del veth-${name}-br
          rm -rf /etc/netns/${name}
        ''
        # Delete prerouting rules
        + strings.concatMapStrings (x: "iptables -t nat -D PREROUTING -p tcp --dport ${builtins.toString x.From} -j DNAT --to-destination ${def.namespaceAddress}:${builtins.toString x.To}" + "\n") def.portMappings;
      }; in "${vpnDown}/bin/${name}-down";
    };
  };

  vpnnamespaceOptions = { name, config, ... }: {
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

      portMappings = mkOption {
        type = with types; listOf (attrsOf port);
        default = [];
        description = mdDoc ''
          A list of pairs mapping ports on
          the host to ports in the namespace.
        '';
        example = [{
          From = 80;
          To = 80;
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
  };
in {
  options.systemd.services = mkOption {
    type = types.attrsOf (types.submodule ({ name, config, ... }: {
      options.vpnconfinement = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = mdDoc ''
            Whether to confine the systemd service in a
            networking namespace which routes traffic through a
            VPN tunnel and forces a specified DNS.
          '';
        };
        vpnnamespace = mkOption {
          type = types.str;
          default = null;
          example = "wg";
          description = mdDoc ''
            Name of the VPN networking namespace to
            use for the systemd service.
          '';
        };
      };

      config = let
        vpn = config.vpnconfinement.vpnnamespace;
      in mkIf config.vpnconfinement.enable {
        bindsTo = [ "${vpn}.service" ];
        after = [ "${vpn}.service" ];
        wantedBy = [ "${vpn}.service" ];

        serviceConfig = {
          NetworkNamespacePath = "/var/run/netns/${vpn}";

          BindReadOnlyPaths = [
            "/etc/netns/${vpn}/resolv.conf:/etc/resolv.conf:norbind"
            "/var/empty:/var/run/nscd:norbind"
            "/var/empty:/var/run/resolvconf:norbind"
          ];

          PrivateMounts = mkDefault true;
        };
      };
    }));
  };

  options.vpnnamespaces = mkOption {
    type = with types; attrsOf (submodule [ vpnnamespaceOptions ]);
  };

  config = {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    systemd.services = {
      "netns@" = {
        description = "%I network namespace";
        before = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.iproute2}/bin/ip netns add %I";
          ExecStop = "${pkgs.iproute2}/bin/ip netns del %I";
        };
      };
    } // mapAttrs' (n: v: nameValuePair n (namespaceToService n v)) config.vpnnamespaces;
  };
}


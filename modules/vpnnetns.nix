{ lib, pkgs, config, ... }:
with lib;
let
  namespaceToService = name: def: {
    description = "${name} network interface";
    after = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = let
      vpnUp = pkgs.writeShellApplication {
        name = "${name}-up";
        runtimeInputs = with pkgs; [ iproute2 wireguard-tools iptables bash ];
        text = ''
          # Set up the wireguard interface
          ip netns add ${name}
          ip link add ${name}0 type wireguard
          ip link set ${name}0 netns ${name}

          # Parse wireguard INI config file
          # shellcheck disable=SC1090
          source <(grep -e "DNS" -e "Address" ${def.wireguardConfigFile} | tr -d ' ')

          # Add Addresses
          IFS=","
          # shellcheck disable=SC2154
          for addr in $Address; do
              ip -n ${name} address add "$addr" dev ${name}0
          done

          # Set wireguard config
          ip netns exec ${name} \
            wg setconf ${name}0 <(wg-quick strip ${def.wireguardConfigFile})

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

          # Set up firewall
          ip netns exec ${name} iptables -P INPUT DROP
          ip netns exec ${name} iptables -P FORWARD DROP
          ip netns exec ${name} iptables -A INPUT -i lo -j ACCEPT
          ip netns exec ${name} iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
          ip netns exec ${name} iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

          # Drop packets to unspecified DNS
          ip netns exec ${name} iptables -N dns-fw
          ip netns exec ${name} iptables -A dns-fw -j DROP
          ip netns exec ${name} iptables -I OUTPUT -p udp -m udp --dport 53 -j dns-fw

          # Add DNS
          rm -rf /etc/netns/${name}
          mkdir -p /etc/netns/${name}
          IFS=","
          # shellcheck disable=SC2154
          for ns in $DNS; do
              echo "nameserver $ns" >> /etc/netns/${name}/resolv.conf
              ip netns exec ${name} iptables -I dns-fw -p udp -d "$ns" -j ACCEPT
          done
        ''
        # Add routes to make the namespace accessible
        + strings.concatMapStrings (x: "ip -n ${name} route add ${x} via ${def.bridgeAddress}" + "\n") def.accessibleFrom

        # Add prerouting rules
        + ''
          iptables -t nat -N ${name}-prerouting
          iptables -t nat -A PREROUTING -j ${name}-prerouting
        ''
        + strings.concatMapStrings (x: "iptables -t nat -A ${name}-prerouting -p tcp --dport ${builtins.toString x.from} -j DNAT --to-destination ${def.namespaceAddress}:${builtins.toString x.to}" + "\n") (filter (m: !(builtins.isNull (builtins.match ("tcp|both") m.protocol))) def.portMappings)
        + strings.concatMapStrings (x: "iptables -t nat -A ${name}-prerouting -p udp --dport ${builtins.toString x.from} -j DNAT --to-destination ${def.namespaceAddress}:${builtins.toString x.to}" + "\n") (filter (m: !(builtins.isNull (builtins.match ("udp|both") m.protocol))) def.portMappings)

        # Add veth INPUT rules
        + strings.concatMapStrings (x: "ip netns exec ${name} iptables -A INPUT -p tcp --dport ${builtins.toString x.to} -j ACCEPT -i veth-${name}" + "\n") (filter (m: !(builtins.isNull (builtins.match ("tcp|both") m.protocol))) def.portMappings)
        + strings.concatMapStrings (x: "ip netns exec ${name} iptables -A INPUT -p udp --dport ${builtins.toString x.to} -j ACCEPT -i veth-${name}" + "\n") (filter (m: !(builtins.isNull (builtins.match ("udp|both") m.protocol))) def.portMappings)

        # Add VPN INPUT rules
        + strings.concatMapStrings (x: "ip netns exec ${name} iptables -A INPUT -p tcp --dport ${builtins.toString x.port} -j ACCEPT -i ${name}0" + "\n") (filter (m: !(builtins.isNull (builtins.match ("tcp|both") m.protocol))) def.openVPNPorts)
        + strings.concatMapStrings (x: "ip netns exec ${name} iptables -A INPUT -p udp --dport ${builtins.toString x.port} -j ACCEPT -i ${name}0" + "\n") (filter (m: !(builtins.isNull (builtins.match ("udp|both") m.protocol))) def.openVPNPorts);
      };

      vpnDown = pkgs.writeShellApplication {
        name = "${name}-down";
        runtimeInputs = with pkgs; [ iproute2 iptables gawk ];
        text = ''
          ip netns del ${name}
          ip link del ${name}-br
          ip link del veth-${name}-br
          rm -rf /etc/netns/${name}
        ''
        # Delete prerouting rules
        + ''
          while read -r rule
          do
            # shellcheck disable=SC2086
            iptables -t nat -D ''${rule#* }
          done < <(iptables -t nat -S | awk '/${name}-prerouting/ && !/-N/')

          iptables -t nat -X ${name}-prerouting
        '';
      };
    in {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = "${vpnUp}/bin/${name}-up";
      ExecStopPost = "${vpnDown}/bin/${name}-down";
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
    systemd.services = mapAttrs' (n: v: nameValuePair n (namespaceToService n v)) config.vpnnamespaces;
  };
}


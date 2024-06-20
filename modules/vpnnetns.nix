{ lib, pkgs, config, ... }:
with lib;
let
  firewallUtils = import ./firewall-utils.nix { inherit lib; };
  namespaceToService = name: def: assert builtins.stringLength name < 8; {
    description = "${name} network interface";
    before = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = let
      vpnUp = pkgs.writeShellApplication {
        name = "${name}-up";
        runtimeInputs = with pkgs; [ iproute2 wireguard-tools iptables bash ];
        text = ''
          ip netns add ${name}

          # Set up the wireguard interface
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

          # Strips the config of wg-quick settings
          shopt -s extglob
          strip_wgquick_config() {
            CONFIG_FILE="$1"
            [[ -e $CONFIG_FILE ]] || (echo "'$CONFIG_FILE' does not exist" >&2 && exit 1)
            CONFIG_FILE="$(readlink -f "$CONFIG_FILE")"
            local interface_section=0
            while read -r line || [[ -n $line ]]; do
              key=''${line//=/ }
              [[ $key == "["* ]] && interface_section=0
              [[ $key == "[Interface]" ]] && interface_section=1
              if [ $interface_section -eq 1 ] &&
                [[ $key =~ Address|MTU|DNS|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig ]]
              then
                continue
              fi
              WG_CONFIG+="$line"$'\n'
            done < "$CONFIG_FILE"
            echo "$WG_CONFIG"
          }

          # Set wireguard config
          ip netns exec ${name} \
            wg setconf ${name}0 <(strip_wgquick_config ${def.wireguardConfigFile})

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
          ip link set dev veth-${name}-br up

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
            if [[ $ns == *":"* ]]; then continue; fi  # Skip ipv6
            echo "nameserver $ns" >> /etc/netns/${name}/resolv.conf
            ip netns exec ${name} iptables -I dns-fw -p udp -d "$ns" -j ACCEPT
          done

          # Add routes to make the namespace accessible
          ${strings.concatMapStrings (x: "ip -n ${name} route add ${x} via ${def.bridgeAddress}" + "\n") def.accessibleFrom}

          # Add prerouting rules
          iptables -t nat -N ${name}-prerouting
          iptables -t nat -A PREROUTING -j ${name}-prerouting
          ${firewallUtils.generatePreroutingRules "${name}-prerouting" def.namespaceAddress def.portMappings}

          # Add veth INPUT rules
          ${firewallUtils.generateNetNSInputRules name "veth-${name}" def.portMappings}

          # Add VPN INPUT rules
          ${firewallUtils.generateNetNSVPNInputRules name "${name}0" def.openVPNPorts}
        '';
      };

      vpnDown = pkgs.writeShellApplication {
        name = "${name}-down";
        runtimeInputs = with pkgs; [ iproute2 iptables gawk ];
        text = ''
          set +o errexit

          ip netns del ${name}
          ip link del ${name}-br
          ip link del veth-${name}-br
          rm -rf /etc/netns/${name}

          # Delete prerouting rules
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
in {
  imports = [ ./systemd.nix ]; # Confinement options for systemd services

  options.vpnnamespaces = mkOption {
    type = with types; attrsOf (submodule [ (import ./options.nix) ]);
  };

  config = {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    systemd.services = mapAttrs' (n: v: nameValuePair n (namespaceToService n v)) config.vpnnamespaces;
  };
}

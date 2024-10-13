{ lib, pkgs, config, ... }:
with lib;
let
  addNetNSRules = netns: argset: concatStringsSep "\n"
    (map (args: "ip netns exec ${netns} iptables ${args}\nip netns exec ${netns} ip6tables ${args}") argset);
  firewallUtils = import ./firewall-utils.nix { inherit lib; };
  utils = import ../lib/utils.nix { inherit lib; };
  namespaceToService = name: def: assert builtins.stringLength name < 8; {
    description = "${name} network interface";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = let
      vpnUp = pkgs.writeShellApplication {
        name = "${name}-up";
        runtimeInputs = with pkgs; [ iproute2 wireguard-tools iptables bash unixtools.ping ];
        text = ''
          ip netns add ${name}

          # Set up netns firewall
          ${addNetNSRules name [
            "-P INPUT DROP"
            "-P FORWARD DROP"
            "-A INPUT -i lo -j ACCEPT"
            "-A INPUT -m conntrack --ctstate INVALID -j DROP"
            "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
          ]}

          ip netns exec ${name} ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

          # Drop packets to unspecified DNS
          ${addNetNSRules name [
            "-N dns-fw"
            "-A dns-fw -j DROP"
            "-I OUTPUT -p udp -m udp --dport 53 -j dns-fw"
          ]}

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

          # Add DNS
          rm -rf /etc/netns/${name}
          mkdir -p /etc/netns/${name}
          IFS=","
          # shellcheck disable=SC2154
          for ns in $DNS; do
            echo "nameserver $ns" >> /etc/netns/${name}/resolv.conf
            if [[ $ns == *"."* ]]; then
              ip netns exec ${name} iptables -I dns-fw -p udp -d "$ns" -j ACCEPT
            else
              ip netns exec ${name} ip6tables -I dns-fw -p udp -d "$ns" -j ACCEPT
            fi
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

          until ping -c1 1dot1dot1dot1.cloudflare-dns.com > /dev/null 2>&1; do sleep 1; done;

          # Set wireguard config
          ip netns exec ${name} \
            wg setconf ${name}0 <(strip_wgquick_config ${def.wireguardConfigFile})

          ip -n ${name} link set ${name}0 up
          ip -n ${name} route add default dev ${name}0
          ip -6 -n ${name} route add default dev ${name}0

          # Start the loopback interface
          ip -n ${name} link set dev lo up

          # Create a bridge
          ip link add ${name}-br type bridge
          ip addr add ${def.bridgeAddress}/24 dev ${name}-br
          ip addr add ${def.bridgeAddressIPv6}/64 dev ${name}-br
          ip link set dev ${name}-br up

          # Set up veth pair to link namespace with host network
          ip link add veth-${name}-br type veth peer name veth-${name} netns ${name}
          ip link set veth-${name}-br master ${name}-br
          ip link set dev veth-${name}-br up

          ip -n ${name} addr add ${def.namespaceAddress}/24 dev veth-${name}
          ip -n ${name} addr add ${def.namespaceAddressIPv6}/64 dev veth-${name}
          ip -n ${name} link set dev veth-${name} up

          # Add routes to make the namespace accessible
          ${strings.concatMapStrings (x: ''
            ip -n ${name} route add ${x} via \
            ${if utils.isValidIPv4 x then def.bridgeAddress else def.bridgeAddressIPv6}
          ''
          ) def.accessibleFrom}

          # Add prerouting rules
          iptables -t nat -N ${name}-prerouting
          iptables -t nat -A PREROUTING -j ${name}-prerouting
          ip6tables -t nat -N ${name}-prerouting
          ip6tables -t nat -A PREROUTING -j ${name}-prerouting
          ${firewallUtils.generatePreroutingRules "${name}-prerouting" def.namespaceAddress def.namespaceAddressIPv6 def.portMappings}

          # Add veth INPUT rules
          ${firewallUtils.generatePortMapRules name "veth-${name}" def.portMappings}

          # Add VPN INPUT rules
          ${firewallUtils.generateAllowedPortRules name "${name}0" def.openVPNPorts}
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
          while read -r rule
          do
            # shellcheck disable=SC2086
            ip6tables -t nat -D ''${rule#* }
          done < <(ip6tables -t nat -S | awk '/${name}-prerouting/ && !/-N/')

          iptables -t nat -X ${name}-prerouting
          ip6tables -t nat -X ${name}-prerouting
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
  imports = [ ./systemd.nix ] # Confinement options for systemd services
    ++ [(mkRenamedOptionModule [ "vpnnamespaces" ] [ "vpnNamespaces" ])];

  options.vpnNamespaces = mkOption {
    type = with types; attrsOf (submodule [ (import ./options.nix) ]);
    default = {};
  };

  config = mkIf (config.vpnNamespaces != {}) {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    systemd.services = mapAttrs' (n: v: nameValuePair n (namespaceToService n v)) config.vpnNamespaces;
    systemd.tmpfiles.rules = [ "d /var/run/resolvconf 0755 root root" ]; # Make sure resolvconf path exists
  };
}

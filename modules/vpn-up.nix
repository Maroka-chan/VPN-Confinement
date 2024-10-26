{ pkgs, lib, optionalIPv6String }: netnsName: def:
let
  inherit (lib) concatMapStrings;

  firewallUtils = import ./firewall-utils.nix {
    inherit lib optionalIPv6String;
  };
  inherit (firewallUtils)
    addNetNSIPRules
    generatePortMapRules
    generatePreroutingRules
    generateAllowedPortRules
  ;

  utils = import ../lib/utils.nix { inherit lib; };
  inherit (utils) isValidIPv4;

in pkgs.writeShellApplication {
  name = "${netnsName}-up";
  runtimeInputs = with pkgs; [
    bash
    iproute2
    iptables
    unixtools.ping
    wireguard-tools
  ];
  text = ''
    ip netns add ${netnsName}

    # Set up netns firewall
    ${addNetNSIPRules netnsName [
      "-P INPUT DROP"
      "-P FORWARD DROP"
      "-A INPUT -i lo -j ACCEPT"
      "-A INPUT -m conntrack --ctstate INVALID -j DROP"
      "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    ]}

    ${optionalIPv6String
      "ip netns exec ${netnsName} ip6tables -A INPUT -p ipv6-icmp -j ACCEPT"
    }

    # Drop packets to unspecified DNS
    ${addNetNSIPRules netnsName [
      "-N dns-fw"
      "-A dns-fw -j DROP"
      "-I OUTPUT -p udp -m udp --dport 53 -j dns-fw"
    ]}

    # Set up the wireguard interface
    ip link add ${netnsName}0 type wireguard
    ip link set ${netnsName}0 netns ${netnsName}

    # Parse wireguard INI config file
    # shellcheck disable=SC1090
    source <( \
      grep -e "DNS" -e "Address" ${def.wireguardConfigFile} \
        | tr -d ' ' \
    )

    # Add Addresses
    IFS=","
    # shellcheck disable=SC2154
    for addr in $Address; do
      ip -n ${netnsName} address add "$addr" dev ${netnsName}0
    done

    # Add DNS
    rm -rf /etc/netns/${netnsName}
    mkdir -p /etc/netns/${netnsName}
    IFS=","
    # shellcheck disable=SC2154
    for ns in $DNS; do
      echo "nameserver $ns" >> /etc/netns/${netnsName}/resolv.conf
      if [[ $ns == *"."* ]]; then
        ip netns exec ${netnsName} iptables \
          -I dns-fw -p udp -d "$ns" -j ACCEPT
      ${optionalIPv6String ''
      else
        ip netns exec ${netnsName} ip6tables \
          -I dns-fw -p udp -d "$ns" -j ACCEPT
      ''}
      fi
    done

    # Strips the config of wg-quick settings
    shopt -s extglob
    strip_wgquick_config() {
      CONFIG_FILE="$1"
      [[ -e $CONFIG_FILE ]] \
        || (echo "'$CONFIG_FILE' does not exist" >&2 && exit 1)
      CONFIG_FILE="$(readlink -f "$CONFIG_FILE")"
      local interface_section=0
      while read -r line || [[ -n $line ]]; do
        key=''${line//=/ }
        [[ $key == "["* ]] && interface_section=0
        [[ $key == "[Interface]" ]] && interface_section=1
        if [ $interface_section -eq 1 ] && [[ $key =~ \
          Address|MTU|DNS|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig \
        ]]
        then
          continue
        fi
        WG_CONFIG+="$line"$'\n'
      done < "$CONFIG_FILE"
      echo "$WG_CONFIG"
    }

    # Wait for internet to be reachable
    until ping -c1 1dot1dot1dot1.cloudflare-dns.com > /dev/null 2>&1; do
      sleep 1
    done

    # Set wireguard config
    ip netns exec ${netnsName} \
      wg setconf ${netnsName}0 \
        <(strip_wgquick_config ${def.wireguardConfigFile})

    ip -n ${netnsName} link set ${netnsName}0 up

    # Start the loopback interface
    ip -n ${netnsName} link set dev lo up

    # Create a bridge
    ip link add ${netnsName}-br type bridge
    ip addr add ${def.bridgeAddress}/24 dev ${netnsName}-br
    ${optionalIPv6String ''
    ip addr add ${def.bridgeAddressIPv6}/64 dev ${netnsName}-br
    ''}
    ip link set dev ${netnsName}-br up

    # Set up veth pair to link namespace with host network
    ip link add veth-${netnsName}-br type veth peer \
      name veth-${netnsName} netns ${netnsName}
    ip link set veth-${netnsName}-br master ${netnsName}-br
    ip link set dev veth-${netnsName}-br up

    ip -n ${netnsName} addr add ${def.namespaceAddress}/24 \
      dev veth-${netnsName}
    ${optionalIPv6String ''
    ip -n ${netnsName} addr add ${def.namespaceAddressIPv6}/64 \
      dev veth-${netnsName}
    ''}
    ip -n ${netnsName} link set dev veth-${netnsName} up

    # Add routes
    ip -n ${netnsName} route add default dev ${netnsName}0
    ${optionalIPv6String ''
    ip -6 -n ${netnsName} route add default dev ${netnsName}0
    ''}

    ${concatMapStrings (x: if isValidIPv4 x then ''
      ip -n ${netnsName} route add ${x} via ${def.bridgeAddress}
    '' else optionalIPv6String ''
      ip -n ${netnsName} route add ${x} via ${def.bridgeAddressIPv6}
    ''
    ) def.accessibleFrom}

    # Add prerouting rules
    iptables -t nat -N ${netnsName}-prerouting
    iptables -t nat -A PREROUTING -j ${netnsName}-prerouting
    ${optionalIPv6String ''
    ip6tables -t nat -N ${netnsName}-prerouting
    ip6tables -t nat -A PREROUTING -j ${netnsName}-prerouting
    ''}
    ${generatePreroutingRules "${netnsName}-prerouting"
      def.namespaceAddress def.namespaceAddressIPv6 def.portMappings}

    # Add veth INPUT rules
    ${generatePortMapRules netnsName "veth-${netnsName}" def.portMappings}

    # Add VPN INPUT rules
    ${generateAllowedPortRules netnsName "${netnsName}0" def.openVPNPorts}
  '';
}

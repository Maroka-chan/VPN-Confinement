{
  pkgs,
  lib,
  optionalIPv6String,
}: netnsName: def: let
  inherit (lib) concatMapStrings;

  firewallUtils = import ./firewall-utils.nix {
    inherit lib optionalIPv6String;
  };
  inherit
    (firewallUtils)
    addIPRules
    addNetNSIPRules
    generatePortMapRules
    generatePreroutingRules
    generateAllowedPortRules
    ;

  utils = import ../lib/utils.nix {inherit lib;};
  inherit (utils) isValidIPv4;

  routeDestinations = lib.unique (def.allowedEgress ++ def.accessibleFrom);
in
  pkgs.writeShellApplication {
    name = "${netnsName}-up";
    runtimeInputs = with pkgs; [
      bash
      iproute2
      iptables
      unixtools.ping
      wireguard-tools
    ];
    text = ''
      # Warn if config is world readable
      if (( ($(stat -c '0%#a' "${def.wireguardConfigFile}") & 0007) != 0 )); then
        echo "Warning: '${def.wireguardConfigFile}' is world readable" >&2
      fi

      ip netns add ${netnsName}

      # Set up netns firewall
      ${addNetNSIPRules netnsName [
        "-P INPUT DROP"
        "-P FORWARD DROP"
        "-A INPUT -i lo -j ACCEPT"
        "-A INPUT -m conntrack --ctstate INVALID -j DROP"
        "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      ]}

      ${optionalIPv6String "ip netns exec ${netnsName} ip6tables -A INPUT -p ipv6-icmp -j ACCEPT"}

      # Drop packets to unspecified DNS
      ${addNetNSIPRules netnsName [
        "-N dns-fw"
        "-A dns-fw -j DROP"
        "-I OUTPUT -p udp -m udp --dport 53 -j dns-fw"
      ]}

      # Set up the wireguard interface
      ip link add ${netnsName}0 type wireguard
      ip link set ${netnsName}0 netns ${netnsName}

      # Strips the config of wg-quick settings
      WG_CONFIG=""
      ADDRESSES=()
      DNS_SERVERS=()
      DNS_SEARCH=()
      ENDPOINT=""
      MTU=""
      interface_section=0
      shopt -s nocasematch extglob
      while IFS= read -r line || [[ -n $line ]]; do
        stripped="''${line%%#*}"
        key="''${stripped%%=*}"
        key="''${key##*([[:space:]])}"; key="''${key%%*([[:space:]])}"
        value="''${stripped#*=}"
        value="''${value##*([[:space:]])}"; value="''${value%%*([[:space:]])}"

        [[ $key == \[*\] ]] && interface_section=0
        [[ $key == "[Interface]" ]] && interface_section=1

        # Extract Endpoint from [Peer] section
        case "$key" in
          Endpoint)
            ENDPOINT="$value"
            ;;
        esac

        # Strip wg-quick settings from [Interface] section
        if (( interface_section )); then
          # shellcheck disable=SC2206
          case "$key" in
            Address) ADDRESSES+=( ''${value//,/ } ); continue ;;
            MTU) MTU="$value"; continue ;;
            DNS)
              for v in ''${value//,/ }; do
                [[ $v =~ (^[0-9.]+$)|(^.*:.*$) ]] && DNS_SERVERS+=( "$v" ) || DNS_SEARCH+=( "$v" )
              done
              continue
              ;;
            Table|PreUp|PreDown|PostUp|PostDown|SaveConfig)
              # Strip these settings but don't store them
              continue
              ;;
          esac
        fi

        WG_CONFIG+="$line"$'\n'
      done < "${def.wireguardConfigFile}"
      shopt -u nocasematch extglob

      # Throw error when DNS is unset
      if [[ ''${#DNS_SERVERS[@]} -eq 0 ]]; then
        echo "WireGuard configuration error: missing DNS field." >&2
        echo "Please set DNS=<vpn_provided_dns> before continuing." >&2
        exit 1
      fi

      # Add Addresses
      for addr in "''${ADDRESSES[@]}"; do
        ip -n ${netnsName} address add "$addr" dev ${netnsName}0
      done

      # Add DNS
      rm -rf /etc/netns/${netnsName}
      mkdir -p /etc/netns/${netnsName}

      # Generate resolv.conf
      {
        printf 'nameserver %s\n' "''${DNS_SERVERS[@]}"
        [[ ''${#DNS_SEARCH[@]} -eq 0 ]] || printf 'search %s\n' "''${DNS_SEARCH[*]}"
      } > /etc/netns/${netnsName}/resolv.conf

      # Setup DNS firewall rules
      for ns in "''${DNS_SERVERS[@]}"; do
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

      # The wireguard endpoint is an IP address with a port. Extract the address alone, and test for
      # connectivity using ping.
      # shellcheck disable=SC2154
      if [[ $ENDPOINT =~ ^\[?([^]]+)\]?:[0-9]+$ ]]; then
        EndpointIP="''${BASH_REMATCH[1]}"
      else
        echo "invalid endpoint format: '$ENDPOINT'" >&2
        exit 1
      fi

      # Wait for endpoint to be reachable
      attempt=1
      max_retries=5
      success=false
      echo -n "Waiting for wireguard endpoint '$EndpointIP' to be reachable..."
      while [[ $attempt -le $max_retries ]]; do
        ping -c 1 "$EndpointIP" > /dev/null 2>&1 && { success=true; break; }
        sleep 1
        attempt=$((attempt + 1))
      done

      if ! $success; then
        echo # The last echo did not print a newline, print one now
        echo "failed to reach '$EndpointIP' after $max_retries attempts" >&2
        exit 1
      else
        echo " success!"
      fi

      # Set wireguard config
      ip netns exec ${netnsName} \
        wg setconf ${netnsName}0 \
          <(printf '%s' "$WG_CONFIG")

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

      # Set MTU
      mtu=2147483647
      if [[ -n $MTU ]]; then
        mtu="$MTU"
      else
        while read -r _ endpoint; do
          [[ $endpoint =~ ^\[?([a-z0-9:.]+)\]?:[0-9]+$ ]] || continue
          output="$(ip -n ${netnsName} route get "''${BASH_REMATCH[1]}" || true)"
          if [[ $output =~ mtu\ ([0-9]+) ]]; then
            candidate="''${BASH_REMATCH[1]}"
          elif [[ $output =~ dev\ ([^ ]+) ]] && \
               link_out="$(ip -n ${netnsName} link show dev "''${BASH_REMATCH[1]}")" && \
               [[ $link_out =~ mtu\ ([0-9]+) ]]; then
            candidate="''${BASH_REMATCH[1]}"
          else
            continue
          fi
          (( candidate < mtu )) && mtu="$candidate"
        done < <(ip netns exec ${netnsName} wg show ${netnsName}0 endpoints)

        if [[ $mtu -eq 2147483647 ]]; then
          output="$(ip -n ${netnsName} route show default || true)"
          if [[ $output =~ mtu\ ([0-9]+) ]]; then
            mtu="''${BASH_REMATCH[1]}"
          elif [[ $output =~ dev\ ([^ ]+) ]] && \
               link_out="$(ip -n ${netnsName} link show dev "''${BASH_REMATCH[1]}")" && \
               [[ $link_out =~ mtu\ ([0-9]+) ]]; then
            mtu="''${BASH_REMATCH[1]}"
          fi
        fi

        [[ $mtu -gt 0 && $mtu -lt 2147483647 ]] || mtu=1500
        mtu=$(( mtu - 80 ))
      fi
      ip -n ${netnsName} link set mtu "$mtu" up dev ${netnsName}0

      # Routes for every destination reachable via the bridge, from both
      # accessibleFrom and allowedEgress. Deduplicated so a range appearing
      # in both lists cannot fail the script, while a genuinely conflicting
      # route (a full range colliding with the tunnel default) still fails
      # loudly instead of silently replacing it.
      ${concatMapStrings (
          x:
            if isValidIPv4 x
            then ''
              ip -n ${netnsName} route add ${x} via ${def.bridgeAddress}
            ''
            else
              optionalIPv6String ''
                ip -n ${netnsName} route add ${x} via ${def.bridgeAddressIPv6}
              ''
        )
        routeDestinations}

      # Allow the namespace to initiate connections to specific
      # destinations outside the tunnel (allowedEgress). Accepted before
      # the kill switch rules below so these destinations are exempt from
      # the veth NEW drop.
      ${concatMapStrings (
          x:
            if isValidIPv4 x
            then ''
              ip netns exec ${netnsName} iptables -A OUTPUT -o veth-${netnsName} -d ${x} -j ACCEPT
            ''
            else
              optionalIPv6String ''
                ip netns exec ${netnsName} ip6tables -A OUTPUT -o veth-${netnsName} -d ${x} -j ACCEPT
              ''
        )
        def.allowedEgress}

      # Kill switch: only replies may leave via the veth (except allowedEgress)
      ${addNetNSIPRules netnsName [
        "-A OUTPUT -o veth-${netnsName} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        "-A OUTPUT -o veth-${netnsName} -m conntrack --ctstate NEW -j DROP"
      ]}

      # Force all DNS traffic (port 53 TCP/UDP) through
      # the WireGuard interface via policy routing.
      #
      # Traffic on port 53 uses a separate routing table ('51820')
      # so it always exits through the WireGuard interface.
      # This prevents DNS lookups from passing through the veth pair when the
      # nameserver appears in the main routing table. This in practice means
      # that DNS is not leaked when a nameserver is specified in
      # the 'accessibleFrom' option. As a failsafe, the 'dns-leak' chain drops
      # any DNS traffic that falls through to the main table. This can happen
      # if the WireGuard interface or the '51820' route is removed.

      ip -n ${netnsName} route add default dev ${netnsName}0 table 51820

      ip -n ${netnsName} rule add ipproto udp dport 53 lookup 51820 priority 100
      ip -n ${netnsName} rule add ipproto tcp dport 53 lookup 51820 priority 100

      # Guard against DNS leaks when routing table ('51820') is not present.
      # Monitor dropped packets with:
      #   sudo ip netns exec ${netnsName} iptables -L dns-leak -v -n
      ip netns exec ${netnsName} iptables -N dns-leak

      ip netns exec ${netnsName} iptables -A dns-leak \
        -m limit --limit 1/min -j LOG --log-prefix "dns-leak: "
      ip netns exec ${netnsName} iptables -A dns-leak -j DROP

      ip netns exec ${netnsName} iptables -I OUTPUT 1 -o veth-${netnsName} \
        -p udp --dport 53 -j dns-leak
      ip netns exec ${netnsName} iptables -I OUTPUT 1 -o veth-${netnsName} \
        -p tcp --dport 53 -j dns-leak

      ${optionalIPv6String ''
        ip -6 -n ${netnsName} route add default dev ${netnsName}0 table 51820
        ip -6 -n ${netnsName} rule add ipproto udp dport 53 lookup 51820 priority 100
        ip -6 -n ${netnsName} rule add ipproto tcp dport 53 lookup 51820 priority 100

        ip netns exec ${netnsName} ip6tables -N dns-leak
        ip netns exec ${netnsName} ip6tables -A dns-leak \
          -m limit --limit 1/min -j LOG --log-prefix "dns-leak6: "
        ip netns exec ${netnsName} ip6tables -A dns-leak -j DROP
        ip netns exec ${netnsName} ip6tables -I OUTPUT 1 -o veth-${netnsName} \
          -p udp --dport 53 -j dns-leak
        ip netns exec ${netnsName} ip6tables -I OUTPUT 1 -o veth-${netnsName} \
          -p tcp --dport 53 -j dns-leak
      ''}

      # Add prerouting table
      ${addIPRules [
        "-t nat -N ${netnsName}-prerouting"
        "-t nat -A PREROUTING -j ${netnsName}-prerouting"
      ]}

      # Add prerouting rules
      ${
        generatePreroutingRules
        "${netnsName}-prerouting"
        def.namespaceAddress
        def.namespaceAddressIPv6
        def.portMappings
      }

      # Masquerade namespace-initiated traffic to allowedEgress
      # destinations. Without this, packets leave the host with the
      # private namespace source address. The destination either
      # discards them on arrival (rp_filter, no route back to the
      # source) or accepts them and fails to route its replies, so
      # connections never complete regardless.
      ${addIPRules [
        "-t nat -N ${netnsName}-postrouting"
        "-t nat -A POSTROUTING -j ${netnsName}-postrouting"
      ]}

      ${concatMapStrings (
          x:
            if isValidIPv4 x
            then ''
              iptables -t nat -A ${netnsName}-postrouting -s ${def.namespaceAddress} -d ${x} -j MASQUERADE
            ''
            else
              optionalIPv6String ''
                ip6tables -t nat -A ${netnsName}-postrouting -s ${def.namespaceAddressIPv6} -d ${x} -j MASQUERADE
              ''
        )
        def.allowedEgress}

      # Add veth INPUT rules
      ${generatePortMapRules netnsName "veth-${netnsName}" def.portMappings}

      # Add VPN INPUT rules
      ${generateAllowedPortRules netnsName "${netnsName}0" def.openVPNPorts}
    '';
  }

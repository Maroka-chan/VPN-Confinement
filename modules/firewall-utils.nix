{ lib }:
let
  inherit (lib) concatMapStrings;
  inherit (builtins) foldl' toString concatStringsSep;
in rec {
  generatePreroutingRules =
  table: namespaceAddress: namespaceAddressIPv6: portMappings:
    concatStringsSep "\n" (map (portMap:
      concatMapStrings (protocol:
      ''
        iptables -t nat -A ${table} -p ${protocol} \
        --dport ${toString portMap.from} \
        -j DNAT --to-destination \
        ${namespaceAddress}:${toString portMap.to}

        ip6tables -t nat -A ${table} -p ${protocol} \
        --dport ${toString portMap.from} \
        -j DNAT --to-destination \
        \[${namespaceAddressIPv6}\]:${toString portMap.to}
      ''
      )
      (if portMap.protocol == "both"
        then [ "tcp" "udp" ]
        else [ portMap.protocol ]
      )
    ) portMappings);

  generateNetNSInputRules = netns: interface: ports:
    concatStringsSep "\n" (map (port:
      concatMapStrings (protocol:
        addNetNSIPRules netns [
        ''
          -A INPUT -p ${protocol} \
          --dport ${toString port.value} \
          -j ACCEPT -i ${interface}
        ''
        ])
        (if port.protocol == "both"
          then [ "tcp" "udp" ]
          else [ port.protocol ]
        )
      ) ports);

  generatePortMapRules = netns: interface: portMappings:
    generateNetNSInputRules netns interface
      (foldl' (acc: portMap:
        acc ++ [{ value = portMap.to; protocol = portMap.protocol; }]
      ) [] portMappings);

  generateAllowedPortRules = netns: interface: allowedPorts:
    generateNetNSInputRules netns interface
      (foldl' (acc: port:
        acc ++ [{ value = port.port; protocol = port.protocol; }]
      ) [] allowedPorts);

  addIPRules = netns: argset: concatStringsSep "\n"
    (map (args: ''
      iptables ${args}
      ip6tables ${args}
    '') argset);

  addNetNSIPRules = netns: argset: concatStringsSep "\n"
    (map (args: ''
      ip netns exec ${netns} iptables ${args}
      ip netns exec ${netns} ip6tables ${args}
    '') argset);
}

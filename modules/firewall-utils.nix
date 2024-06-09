{ lib, ... }:
with lib;
let
  filterPortsByProtocol = ports: protocol:
      (filter (m: !(builtins.isNull (builtins.match ("${protocol}|both") m.protocol))) ports);

  generatePreroutingRules' = table: namespaceAddress: protocol: portMappings:
    strings.concatMapStrings (x:
      "iptables -t nat -A ${table} -p ${protocol} --dport ${builtins.toString x.from}"
      + " -j DNAT --to-destination ${namespaceAddress}:${builtins.toString x.to}" + "\n")
      (filter (m: !(builtins.isNull (builtins.match ("${protocol}|both") m.protocol))) portMappings);

  generateINPUTRule = netns: interface: protocol: port:
      "ip netns exec ${netns} iptables -A INPUT -p ${protocol}"
      + " --dport ${builtins.toString port} -j ACCEPT -i ${interface}" + "\n";

  generateNetNSInputRules' = netns: interface: protocol: portMappings:
    strings.concatMapStrings (x: generateINPUTRule netns interface protocol x.to)
       (filterPortsByProtocol portMappings protocol);

  generateNetNSVPNInputRules' = netns: interface: protocol: allowedPorts:
    strings.concatMapStrings (x: generateINPUTRule netns interface protocol x.port)
      (filterPortsByProtocol allowedPorts protocol);
in {
  generatePreroutingRules = table: namespaceAddress: portMappings:
    generatePreroutingRules' table namespaceAddress "tcp" portMappings
    + generatePreroutingRules' table namespaceAddress "udp" portMappings;

  generateNetNSInputRules = netns: interface: portMappings:
    generateNetNSInputRules' netns interface "tcp" portMappings
    + generateNetNSInputRules' netns interface "udp" portMappings;

  generateNetNSVPNInputRules = netns: interface: allowedPorts:
    generateNetNSVPNInputRules' netns interface "tcp" allowedPorts
    + generateNetNSVPNInputRules' netns interface "udp" allowedPorts;
}

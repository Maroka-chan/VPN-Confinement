{ lib, ... }:
with lib;
let
  generatePreroutingRules' = table: namespaceAddress: protocol: portMappings:
    strings.concatMapStrings (x:
      "iptables -t nat -A ${table} -p ${protocol} --dport ${builtins.toString x.from}"
      + " -j DNAT --to-destination ${namespaceAddress}:${builtins.toString x.to}" + "\n")
      (filter (m: !(builtins.isNull (builtins.match ("${protocol}|both") m.protocol))) portMappings);

  generateNetNSInputRules' = netns: interface: protocol: portMappings:
    strings.concatMapStrings (x:
      "ip netns exec ${netns} iptables -A INPUT -p ${protocol}"
      + " --dport ${builtins.toString x.to} -j ACCEPT -i ${interface}" + "\n")
      (filter (m: !(builtins.isNull (builtins.match ("${protocol}|both") m.protocol))) portMappings);
in {
  generatePreroutingRules = table: namespaceAddress: portMappings:
    generatePreroutingRules' table namespaceAddress "tcp" portMappings
    + generatePreroutingRules' table namespaceAddress "udp" portMappings;

  generateNetNSInputRules = netns: interface: portMappings:
    generateNetNSInputRules' netns interface "tcp" portMappings
    + generateNetNSInputRules' netns interface "udp" portMappings;
}

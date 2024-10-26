{ pkgs, optionalIPv6String }: netnsName:
pkgs.writeShellApplication {
  name = "${netnsName}-down";
  runtimeInputs = with pkgs; [ iproute2 iptables gawk ];
  text = ''
    set +o errexit

    ip netns del ${netnsName}
    ip link del ${netnsName}-br
    ip link del veth-${netnsName}-br
    rm -rf /etc/netns/${netnsName}

    # Delete prerouting rules
    while read -r rule
    do
      # shellcheck disable=SC2086
      iptables -t nat -D ''${rule#* }
    done < <(iptables -t nat -S | awk '/${netnsName}-prerouting/ && !/-N/')

    ${optionalIPv6String ''
    while read -r rule
    do
      # shellcheck disable=SC2086
      ip6tables -t nat -D ''${rule#* }
    done < <(ip6tables -t nat -S | awk '/${netnsName}-prerouting/ && !/-N/')
    ''}

    iptables -t nat -X ${netnsName}-prerouting
    ${optionalIPv6String ''
    ip6tables -t nat -X ${netnsName}-prerouting
    ''}
  '';
}

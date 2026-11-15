{
  pkgs,
  lib,
  config,
  options,
  ...
}: let
  inherit
    (lib)
    mkIf
    mkMerge
    mkDefault
    mkOption
    mkRenamedOptionModule
    nameValuePair
    mapAttrs'
    mapAttrsToList
    listToAttrs
    optionalString
    concatMap
    concatStringsSep
    imap0
    any
    hasSuffix
    attrValues
    ;
  inherit (lib.types) attrsOf submodule;

  # DNS-SD services of all namespaces, announced by the host (see the dnssd option)
  dnssdServices = concatMap (x: x) (mapAttrsToList (ns: def:
    imap0 (i: service: {
      inherit ns service;
      inherit (def) portMappings;
      fileName = "vpn-${ns}-${toString i}";
    })
    def.dnssd)
  config.vpnNamespaces);

  dnssdProtocol = service:
    if hasSuffix "._udp" service.type
    then "udp"
    else "tcp";

  # The announced port must be reachable from the LAN, i.e. the host side of a
  # port mapping with a matching protocol
  dnssdPortIsMapped = {
    service,
    portMappings,
    ...
  }:
    any (m: m.from == service.port && (m.protocol == dnssdProtocol service || m.protocol == "both"))
    portMappings;

  dnssdFile = {service, ...}: ''
    [Service]
    Name=${service.name}
    Type=${service.type}
    Port=${toString service.port}
    ${optionalString (service.txt != []) "TxtText=${concatStringsSep " " service.txt}"}
  '';

  isIPv6Enabled = config.networking.enableIPv6;
  optionalIPv6String = x: optionalString isIPv6Enabled x;

  namespaceToService = name: def:
    assert builtins.stringLength name < 8; rec {
      description = "${name} network interface";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      restartTriggers = with serviceConfig; [
        ExecStart
        ExecStopPost
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = let
          vpnUp = import ./vpn-up.nix {inherit pkgs lib optionalIPv6String;};
        in "${vpnUp name def}/bin/${name}-up";

        ExecStopPost = let
          vpnDown = import ./vpn-down.nix {inherit pkgs optionalIPv6String;};
        in "${vpnDown name}/bin/${name}-down";
      };
    };
in {
  imports = [./systemd.nix] ++ [(mkRenamedOptionModule ["vpnnamespaces"] ["vpnNamespaces"])];

  options.vpnNamespaces = mkOption {
    type = attrsOf (submodule [(import ./options.nix)]);
    default = {};
  };

  config = mkIf (config.vpnNamespaces != {}) (mkMerge [
    {
      warnings = concatMap (ns: ns.warnings) (attrValues config.vpnNamespaces);

      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = mkIf isIPv6Enabled 1;

      systemd.services = mapAttrs' (n: v: nameValuePair n (namespaceToService n v)) config.vpnNamespaces;

      # Make sure resolvconf path exists
      systemd.tmpfiles.rules = ["d /run/resolvconf 0755 root root"];
    }

    # Announce the namespaces' DNS-SD services from the host via
    # systemd-resolved, with the host's address and the mapped ports
    (mkIf (dnssdServices != []) {
      assertions =
        [
          {
            assertion = config.services.resolved.enable;
            message = "vpnNamespaces.*.dnssd announces services with systemd-resolved; enable services.resolved.";
          }
        ]
        ++ map (s: {
          assertion = dnssdPortIsMapped s;
          message = ''
            vpnNamespaces.${s.ns}.dnssd: "${s.service.name}" announces port ${toString s.service.port},
            which isn't the host side (`from`) of a ${dnssdProtocol s.service} mapping in
            vpnNamespaces.${s.ns}.portMappings, so clients couldn't reach it.
          '';
        })
        dnssdServices;

      warnings = lib.optional (config.services.avahi.enable or false) ''
        vpnNamespaces.*.dnssd announces services with systemd-resolved's mDNS responder,
        but avahi is enabled too. Two mDNS responders on one host conflict; disable one.
      '';

      environment.etc = listToAttrs (map (s:
        nameValuePair "systemd/dnssd/${s.fileName}.dnssd" {text = dnssdFile s;})
      dnssdServices);

      services.resolved =
        if options.services.resolved ? settings
        then {settings.Resolve.MulticastDNS = mkDefault "yes";}
        else {extraConfig = "MulticastDNS=yes";};

      # NetworkManager and systemd-networkd turn mDNS off on the links they
      # manage unless configured. For NetworkManager, enable it as the default
      # for connections that don't set connection.mdns themselves. networkd
      # has to be configured per network, which only the host knows (see the
      # dnssd option); unmanaged links follow resolved's global setting.
      networking.networkmanager.connectionConfig = mkIf config.networking.networkmanager.enable {
        "connection.mdns" = mkDefault 2; # yes
      };

      networking.firewall.allowedUDPPorts = [5353];
    })
  ]);
}

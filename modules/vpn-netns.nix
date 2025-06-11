{ pkgs, lib, config, ... }:
let
  inherit (lib)
    mkIf mkOption mkRenamedOptionModule
    nameValuePair mapAttrs'
    optionalString
  ;
  inherit (lib.types) attrsOf submodule;

  isIPv6Enabled = config.networking.enableIPv6;
  optionalIPv6String = x: optionalString isIPv6Enabled x;

  namespaceToService = name: def:
  assert builtins.stringLength name < 8; {
    description = "${name} network interface";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      ExecStart = let
        vpnUp = import ./vpn-up.nix { inherit pkgs lib optionalIPv6String; };
      in "${vpnUp name def}/bin/${name}-up";

      ExecStopPost = let
        vpnDown = import ./vpn-down.nix { inherit pkgs optionalIPv6String; };
      in "${vpnDown name}/bin/${name}-down";
    };
  };
in {
  imports = [ ./systemd.nix ]
    ++ [(mkRenamedOptionModule [ "vpnnamespaces" ] [ "vpnNamespaces" ])];

  options.vpnNamespaces = mkOption {
    type = attrsOf (submodule [ (import ./options.nix) ]);
    default = {};
  };

  config = mkIf (config.vpnNamespaces != {}) {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" =
      mkIf isIPv6Enabled 1;

    systemd.services = mapAttrs' (n: v:
      nameValuePair n (namespaceToService n v)
    ) config.vpnNamespaces;

    # Make sure resolvconf path exists
    systemd.tmpfiles.rules = [ "d /run/resolvconf 0755 root root" ];
  };
}

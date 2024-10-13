{ pkgs, lib, config, ... }:
let
  inherit (lib)
    mkIf mkOption mkRenamedOptionModule
    nameValuePair mapAttrs'
  ;
  inherit (lib.types) attrsOf submodule;

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
        vpnUp = import ./vpn-up.nix { inherit pkgs lib; };
      in "${vpnUp name def}/bin/${name}-up";

      ExecStopPost = let
        vpnDown = import ./vpn-down.nix { inherit pkgs; };
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
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

    systemd.services = mapAttrs' (n: v:
      nameValuePair n (namespaceToService n v)
    ) config.vpnNamespaces;

    # Make sure resolvconf path exists
    systemd.tmpfiles.rules = [ "d /var/run/resolvconf 0755 root root" ];
  };
}

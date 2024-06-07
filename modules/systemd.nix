{ lib, ... }:
with lib;
{
  options.systemd.services = mkOption {
    type = types.attrsOf (types.submodule ({ name, config, ... }: {
      options.vpnconfinement = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = mdDoc ''
            Whether to confine the systemd service in a
            networking namespace which routes traffic through a
            VPN tunnel and forces a specified DNS.
          '';
        };
        vpnnamespace = mkOption {
          type = types.str;
          default = null;
          example = "wg";
          description = mdDoc ''
            Name of the VPN networking namespace to
            use for the systemd service.
          '';
        };
      };

      config = let
        vpn = config.vpnconfinement.vpnnamespace;
      in mkIf config.vpnconfinement.enable {
        bindsTo = [ "${vpn}.service" ];
        after = [ "${vpn}.service" ];

        serviceConfig = {
          NetworkNamespacePath = "/var/run/netns/${vpn}";

          InaccessiblePaths = [
            "/var/run/nscd"
            "/var/run/resolvconf"
          ];

          BindReadOnlyPaths = [
            "/etc/netns/${vpn}/resolv.conf:/etc/resolv.conf:norbind"
          ];
        };
      };
    }));
  };
}

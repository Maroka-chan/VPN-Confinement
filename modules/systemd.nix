{
  lib,
  config,
  ...
}: let
  inherit
    (lib)
    mkOption
    mkRenamedOptionModule
    mkIf
    mkMerge
    optional
    concatMap
    attrValues
    getAttrFromPath
    showOption
    showFiles
    ;
  inherit
    (lib.types)
    attrsOf
    submodule
    bool
    str
    listOf
    ;

  # Renamed options of each systemd service, as paths within the service
  renamedOptions = [
    {
      from = ["vpnconfinement" "enable"];
      to = ["vpnConfinement" "enable"];
    }
    {
      from = ["vpnconfinement" "vpnnamespace"];
      to = ["vpnConfinement" "vpnNamespace"];
    }
  ];
in {
  options.systemd.services = mkOption {
    type = attrsOf (
      submodule (
        {
          config,
          options,
          name,
          ...
        }: {
          options.vpnConfinement = {
            enable = mkOption {
              type = bool;
              default = false;
              description = ''
                Whether to confine the systemd service in a
                networking namespace which routes traffic through a
                VPN tunnel and forces a specified DNS.
              '';
            };
            vpnNamespace = mkOption {
              type = str;
              default = null;
              example = "wg";
              description = ''
                Name of the VPN networking namespace to
                use for the systemd service.
              '';
            };

            # Collected into the top-level `warnings` below
            warnings = mkOption {
              type = listOf str;
              default = [];
              internal = true;
              visible = false;
            };
          };

          # mkRenamedOptionModule keeps the old names working, but it only
          # prints its warning in a submodule that declares an option called
          # `warnings`. Declaring that here would add it to every systemd
          # service, and evaluation fails if another module declares it too.
          # So the warning is built below in vpnConfinement.warnings, which
          # only this module declares.
          imports = map (rename: mkRenamedOptionModule rename.from rename.to) renamedOptions;

          config = mkMerge [
            {
              vpnConfinement.warnings = concatMap (rename: let
                old = getAttrFromPath rename.from options;
                new = getAttrFromPath rename.to options;
              in
                # Same message as mkRenamedOptionModule, with full option paths
                optional old.isDefined
                "The option `${showOption old.loc}' defined in ${showFiles old.files} has been renamed to `${showOption new.loc}'.")
              renamedOptions;
            }

            (let
              vpn = config.vpnConfinement.vpnNamespace;
            in
              mkIf config.vpnConfinement.enable {
                bindsTo = ["${vpn}.service"];
                after = ["${vpn}.service"];

                serviceConfig = {
                  NetworkNamespacePath = "/run/netns/${vpn}";

                  InaccessiblePaths = [
                    "/run/nscd"
                    "/run/resolvconf"
                  ];

                  BindReadOnlyPaths = [
                    "/etc/netns/${vpn}/resolv.conf:/etc/resolv.conf:norbind"
                  ];
                };
              })
          ];
        }
      )
    );
  };

  config.warnings = concatMap (service: service.vpnConfinement.warnings) (attrValues config.systemd.services);
}

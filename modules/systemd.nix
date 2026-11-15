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

  # With systemd-resolved, /etc/resolv.conf is a symlink into this directory,
  # whose files resolved replaces (writes a new file and renames it over the
  # old one) whenever DNS settings change. A bind mount onto such a file stays
  # on the replaced file, so confined services would silently fall back to the
  # host's resolver, which isn't reachable from the namespace. Instead they
  # get their own empty directory there, holding the namespace's resolv.conf.
  # That also hides resolved's socket, so lookups can't go around the VPN.
  resolvedDir = "/run/systemd/resolve";
  resolvedEnabled = config.services.resolved.enable or false;

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

                  TemporaryFileSystem = mkIf resolvedEnabled ["${resolvedDir}:ro"];

                  BindReadOnlyPaths =
                    if resolvedEnabled
                    then
                      # Both names /etc/resolv.conf may point to (stub or uplink mode)
                      map (file: "/etc/netns/${vpn}/resolv.conf:${resolvedDir}/${file}:norbind")
                      ["stub-resolv.conf" "resolv.conf"]
                    else ["/etc/netns/${vpn}/resolv.conf:/etc/resolv.conf:norbind"];
                };
              })
          ];
        }
      )
    );
  };

  config.warnings = concatMap (service: service.vpnConfinement.warnings) (attrValues config.systemd.services);
}

{
  config,
  lib,
  pkgs,
  ...
}: {
  options.programs.vpntunnel.enable = lib.mkEnableOption "vpntunnel";

  config = lib.mkIf config.programs.vpntunnel.enable {
    systemd.services.vpntunnel-wrapper = let
      wrapperDir = config.security.wrapperDir;
    in {
      description = "Install vpntunnel with capabilities";

      wantedBy = ["sysinit.target"];
      partOf = ["suid-sgid-wrappers.service"];
      after = ["suid-sgid-wrappers.service"];
      before = ["sysinit.target" "shutdown.target"];
      conflicts = ["shutdown.target"];

      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [
          "/nix/store"
          "/run/wrappers"
        ];
      };

      serviceConfig.Type = "oneshot";

      script = ''
        # Ensure wrapper directory exists (created by suid-sgid-wrappers)
        if [ ! -d "${wrapperDir}" ]; then
          echo "Error: ${wrapperDir} does not exist"
          exit 1
        fi

        # Remove old version if exists (for updates)
        rm -f "${wrapperDir}/vpntunnel"

        # Copy vpntunnel binary
        cp ${pkgs.vpntunnel}/bin/vpntunnel "${wrapperDir}/vpntunnel"

        # Prevent races
        chmod 0000 "${wrapperDir}/vpntunnel"
        chown root:root "${wrapperDir}/vpntunnel"

        # Set capabilities WITHOUT cap_setpcap (no ambient conversion)
        ${pkgs.libcap}/bin/setcap cap_sys_admin+ep "${wrapperDir}/vpntunnel"

        # Set executable permissions
        chmod 0511 "${wrapperDir}/vpntunnel"
      '';
    };
  };
}

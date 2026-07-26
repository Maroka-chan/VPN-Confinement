{
  config,
  lib,
  pkgs,
  ...
}: let
  # glibc definitions of insecure environment variables
  #
  # We extract the single header file we need into its own derivation,
  # so that we don't have to pull full glibc sources to build wrappers.
  #
  # They're taken from pkgs.glibc so that we don't have to keep as close
  # an eye on glibc changes. Not every relevant variable is in this header,
  # so we maintain a slightly stricter list in wrapper.c itself as well.
  unsecvars = lib.overrideDerivation (pkgs.srcOnly pkgs.glibc) (
    {name, ...}: {
      name = "${name}-unsecvars";
      installPhase = ''
        mkdir $out
        cp sysdeps/generic/unsecvars.h $out
      '';
    }
  );

  vpntunnel = pkgs.callPackage ({
    stdenv,
    libcap,
  }:
    stdenv.mkDerivation {
      pname = "vpntunnel";
      version = "0.1.0";
      src = ./vpntunnel.c;
      dontUnpack = true;
      nativeBuildInputs = [libcap.dev];
      CFLAGS = ["-lcap" "-O2" "-Wall"];
      buildPhase = ''
        $CC $CFLAGS $src -I${unsecvars} -o vpntunnel
      '';
      installPhase = ''
        install -Dm755 vpntunnel $out/bin/vpntunnel
      '';
    }) {};
in {
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
        cp ${vpntunnel}/bin/vpntunnel "${wrapperDir}/vpntunnel"

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

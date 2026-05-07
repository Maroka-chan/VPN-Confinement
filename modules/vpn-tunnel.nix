{
  config,
  lib,
  pkgs,
  ...
}: let
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
      buildPhase = ''
        gcc -o vpntunnel $src -lcap -O2 -Wall
      '';
      installPhase = ''
        install -Dm755 vpntunnel $out/bin/vpntunnel
      '';
    }) {};
in {
  options.programs.vpntunnel.enable = lib.mkEnableOption "vpntunnel";

  config = lib.mkIf config.programs.vpntunnel.enable {
    environment.systemPackages = [vpntunnel];
    security.wrappers.vpntunnel = {
      owner = "root";
      group = "root";
      source = "${lib.getExe vpntunnel}";
      capabilities = "cap_sys_admin,cap_net_raw+ep";
    };
  };
}

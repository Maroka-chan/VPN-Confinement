{
  stdenv,
  libcap,
  srcOnly,
  glibc,
  lib,
}: let
  # glibc definitions of insecure environment variables
  #
  # We extract the single header file we need into its own derivation,
  # so that we don't have to pull full glibc sources to build wrappers.
  #
  # They're taken from pkgs.glibc so that we don't have to keep as close
  # an eye on glibc changes. Not every relevant variable is in this header,
  # so we maintain a slightly stricter list in wrapper.c itself as well.
  unsecvars = lib.overrideDerivation (srcOnly glibc) (
    {name, ...}: {
      name = "${name}-unsecvars";
      installPhase = ''
        mkdir $out
        cp sysdeps/generic/unsecvars.h $out
      '';
    }
  );
in
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
  }

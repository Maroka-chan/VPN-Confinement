{ lib, ... }:
let
  inherit (import ./utils.nix { inherit lib; }) isValidIPv4 isValidIPv6;
  inherit (lib) mkOptionType mergeEqualOption;
in {
  ipv4 = mkOptionType {
    name = "ipv4";
    description = "valid ipv4 address with optional mask";
    descriptionClass = "noun";
    check = isValidIPv4;
    merge = mergeEqualOption;
  };

  ipv6 = mkOptionType {
    name = "ipv6";
    description = "valid ipv6 address with optional mask";
    descriptionClass = "noun";
    check = isValidIPv6;
    merge = mergeEqualOption;
  };

  ipAddress = mkOptionType {
    name = "ipAddress";
    description = "valid ipv4 or ipv6 address with optional mask";
    check = isValidIPv4 || isValidIPv6;
    merge = mergeEqualOption;
  };
}

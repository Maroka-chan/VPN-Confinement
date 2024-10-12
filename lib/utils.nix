{ lib }:
let
  inherit (lib) splitString tryEval toInt count concatStrings sublist;
  inherit (builtins) length elemAt all match;
in rec {
  isValidIPv4 = ip:
  let
    maskSplit = splitString "/" ip;
    maskSplitLen = length maskSplit;
    ipaddr = elemAt maskSplit 0;
    maskstr = if maskSplitLen > 1 then elemAt maskSplit 1 else null;
    octets = splitString "." ipaddr;
  in
    # Validate mask if present
    maskSplitLen <= 2
    && (maskstr == null
      || (
        let
          mask = tryEval (toInt maskstr);
        in
          maskstr != "-0"
          && mask.success
          && mask.value >= 0
          && mask.value <= 32
      )
    )

    # Ensure IP has exactly 4 octets (x.x.x.x)
    && (length octets) == 4

    # Ensure all octets are within the 8-bit range
    && all
      (octetstr:
        let
          octet = tryEval (toInt octetstr);
        in
          octetstr != "-0"
          && octet.success
          && octet.value >= 0
          && octet.value <= 255
      ) octets;


  isValidIPv6 = ip:
  let
    maskSplit = splitString "/" ip;
    maskSplitLen = length maskSplit;
    ipaddr = elemAt maskSplit 0;
    maskstr = if maskSplitLen > 1 then elemAt maskSplit 1 else null;
    segments = splitString ":" ipaddr;
    emptySegments = count (segmentstr: segmentstr == "") segments;
    segmentLength = length segments;
  in
    # Validate mask if present
    maskSplitLen <= 2
    && (maskstr == null
      || (
        let
          mask = tryEval (toInt maskstr);
        in
          mask.success
          && mask.value >= 1
          && mask.value <= 128
      )
    )

    # Ensure zero compression (::) only appears once
    && (
      emptySegments <= 2
      || (
        emptySegments == 3 && segmentLength == 3
      )
    )
    # Ensure IP does not have single trailing colons. Example: ":1:"
    && !hasSingularTrailingColon segments

    # Ensure correct amount of segments with and without zero compression
    && (
      segmentLength == 8
      || (
        segmentLength <= 7
        && emptySegments > 0
      )
      || (
        segmentLength == 9
        && hasTrailingZeroCompression segments
      )
    )

    # Ensure all segments have valid hexademical numbers
    && all
      (segmentstr: (match "[0-9A-Fa-f]{0,4}" segmentstr) != null)
      segments;


  hasTrailingZeroCompression = segments:
  let
    segmentLength = length segments;
  in 
    concatStrings (sublist 0 2 segments) == ""
    || (concatStrings
      (sublist (segmentLength - 2) 2 segments)
    ) == "";


  hasSingularTrailingColon = segments:
  let
    segmentLength = length segments;
  in 
    ((elemAt segments 0) == "" && (elemAt segments 1) != "")
    || (
      (elemAt segments (segmentLength - 1)) == ""
      && (elemAt segments (segmentLength - 2)) != ""
    );
}

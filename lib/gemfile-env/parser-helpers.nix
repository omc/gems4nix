# Pure helper functions for parsing Gemfile.lock
# Extracted for testability: no runCommand, no IO.
{ lib }:

let

  # when a list has many matching elements, return them all
  findIndices =
    pred: list:
    let
      loop =
        idx: xs:
        if xs == [ ] then
          [ ]
        else
          let
            head = builtins.head xs;
            tail = builtins.tail xs;
            rest = loop (idx + 1) tail;
          in
          if pred head then [ idx ] ++ rest else rest;
    in
    loop 0 list;

  # given a bunch of lines, and a starting point offset, return a list of lines
  # until the first blank line
  takeLines =
    start: lines:
    let
      tail = builtins.tail (lib.drop start lines);
      takeUntilEmpty =
        builtins.foldl'
          (
            acc: line:
            if acc.done || line == "" then
              acc
              // {
                done = true;
                lines = acc.lines;
              }
            else
              acc // { lines = acc.lines ++ [ line ]; }
          )
          {
            lines = [ ];
            done = false;
          }
          tail;
    in
    takeUntilEmpty.lines;

  # parse a gem checksum line
  # "  zeitwerk (2.6.18) sha256=bd2d213996ff7b3b364cd342a585fbee9797dbc1c0c6d868dc4150cc75739781"
  parseChecksumLine =
    line:
    let
      stripped = lib.strings.removePrefix "  " line;
      parts = lib.splitString " " stripped;
      numParts = builtins.length parts;

      # validate: we expect exactly "NAME (VERSION) HASH=DIGEST"
      _ =
        if numParts < 3 then
          throw "parseChecksumLine: expected 'NAME (VERSION) sha256=DIGEST' but got ${toString numParts} parts in line: ${line}"
        else if builtins.elemAt parts 0 == "" then
          throw "parseChecksumLine: unexpected leading whitespace in line: ${line}"
        else
          true;

      gemName = builtins.elemAt parts 0;
      rawVersion = builtins.elemAt parts 1;

      __ =
        if !(lib.strings.hasPrefix "(" rawVersion) then
          throw "parseChecksumLine: expected version in parens, e.g. '(1.0.0)', but got '${rawVersion}' in line: ${line}"
        else
          true;

      versionParts = lib.splitString "-" (
        lib.strings.removeSuffix ")" (lib.strings.removePrefix "(" rawVersion)
      );
      version = builtins.elemAt versionParts 0;
      platform =
        if builtins.length versionParts > 1 then
          (lib.strings.concatStringsSep "-" (lib.lists.drop 1 versionParts))
        else
          "ruby";

      rawHash = builtins.elemAt parts 2;
      hashParts = lib.splitString "=" rawHash;

      ___ =
        if builtins.length hashParts < 2 then
          throw "parseChecksumLine: expected 'sha256=DIGEST' but got '${rawHash}' in line: ${line}"
        else
          true;

      sha256 = builtins.elemAt hashParts 1;
    in
    # force validation before returning
    assert _ == true;
    assert __ == true;
    assert ___ == true;
    {
      inherit
        version
        platform
        gemName
        ;
      source = {
        inherit sha256;
      };
    };

  # given a bunch of lines that represent a GEM section, return the remote and the list of gems.
  # we're not concerned with the version specs here, since we'll get that later from the checksum.
  # this is just to reconstruct a url to the gem file later.
  parseGemSection =
    lines:
    let
      remoteStr = builtins.elemAt (lib.strings.splitString ": " (builtins.elemAt lines 0)) 1;
      remote =
        if (lib.strings.hasSuffix "/" remoteStr) then lib.strings.removeSuffix "/" remoteStr else remoteStr;
      gems = lib.lists.map (
        line:
        let
          parts = builtins.filter (s: s != "") (lib.strings.splitString " " line);
          name = builtins.elemAt parts 0;
        in
        name
      ) (lib.lists.drop 2 lines);
    in
    {
      inherit remote gems;
    };

  # ── lockfile-level assembly (pure, no IO) ────────────────────

  # Parse the full content of a Gemfile.lock into its checksum and GEM sections.
  # Returns: { checksumSection, gemSections }
  parseLockfileContent = content:
    let
      lines = lib.splitString "\n" content;

      # CHECKSUMS
      checksumSectionIndex = lib.lists.findFirstIndex (line: line == "CHECKSUMS") null lines;
      checksumSectionLines =
        if checksumSectionIndex == null then
          throw "cannot find CHECKSUMS in Gemfile.lock - run 'bundle lock --add-checksums'"
        else
          takeLines checksumSectionIndex lines;
      checksumSection = lib.lists.map parseChecksumLine checksumSectionLines;

      # GEM sections (may have more than one remote)
      gemSectionIndices = findIndices (l: l == "GEM") lines;
      gemSectionLines = lib.lists.map (i: takeLines i lines) gemSectionIndices;
      gemSections = lib.lists.map parseGemSection gemSectionLines;
    in
    { inherit checksumSection gemSections; };

  # Invert gem sections into a flat { gemName = remote; ... } lookup.
  # Last-writer-wins when a gem appears in multiple sections.
  # TODO: group by gem name for multiple remotes; e.g., depot depends on faraday
  # which shows up in both but we prefer rubygems.org.
  buildGemRemotes = gemSections:
    builtins.listToAttrs (
      lib.lists.flatten (
        lib.lists.map (
          section:
          lib.lists.map (gem: {
            name = gem;
            value = section.remote;
          }) section.gems
        ) gemSections
      )
    );

  # Merge parsed checksums with group info and remote URLs into the final
  # gem metadata list that the rest of the pipeline expects.
  mergeGemMetadata = { checksumSection, gemRemotes, gemGroups }:
    lib.lists.map (gemAttrs: {
      inherit (gemAttrs)
        gemName
        platform
        version
        ;

      # Build-time deps (e.g., mini_portile2) may appear in the lock but not
      # in the group parser output. Default to empty groups so they get
      # filtered out rather than crashing.
      groups = gemGroups.${gemAttrs.gemName} or [ ];

      source = gemAttrs.source // {
        remotes = [ gemRemotes.${gemAttrs.gemName} ];
        type = "gem"; # todo: git, path sources
      };
    }) checksumSection;

in
{
  inherit
    findIndices
    takeLines
    parseChecksumLine
    parseGemSection
    parseLockfileContent
    buildGemRemotes
    mergeGemMetadata
    ;
}

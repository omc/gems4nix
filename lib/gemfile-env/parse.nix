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

  # Known Ruby gem platform strings. Used by parseChecksumLine to parse
  # version-platform from the right, avoiding mis-parses on pre-release
  # versions containing `-` (e.g., `1.0.0-beta.1-arm64-darwin`).
  knownPlatforms = [
    # macOS
    "arm64-darwin"
    "x86_64-darwin"
    "universal-darwin"
    # Linux GNU
    "aarch64-linux-gnu"
    "arm-linux-gnu"
    "x86_64-linux-gnu"
    # Linux musl
    "aarch64-linux-musl"
    "arm-linux-musl"
    "x86_64-linux-musl"
    # Generic linux (no libc suffix)
    "aarch64-linux"
    "x86_64-linux"
    "arm-linux"
    # Java / JRuby
    "java"
    # Windows
    "x86-mingw32"
    "x64-mingw32"
    "x64-mingw-ucrt"
    # MSWIN
    "x86-mswin32"
    "x64-mswin64"
  ];

  # Check if a version-platform string ends with a known platform.
  # Returns { version, platform } where platform is "ruby" if no known
  # platform suffix is found.
  splitVersionPlatform =
    raw:
    let
      # Try each known platform: check if raw ends with "-<platform>"
      matchPlatform = builtins.foldl' (
        acc: plat:
        if acc != null then
          acc
        else
          let
            suffix = "-${plat}";
          in
          if lib.strings.hasSuffix suffix raw then
            {
              version = lib.strings.removeSuffix suffix raw;
              platform = plat;
            }
          else
            null
      ) null knownPlatforms;
    in
    if matchPlatform != null then
      matchPlatform
    else
      {
        version = raw;
        platform = "ruby";
      };

  # parse a gem checksum line
  # "  zeitwerk (2.6.18) sha256=bd2d213996ff7b3b364cd342a585fbee9797dbc1c0c6d868dc4150cc75739781"
  parseChecksumLine =
    line:
    let
      stripped = lib.strings.removePrefix "  " line;
      parts = lib.splitString " " stripped;
      numParts = builtins.length parts;

      # Git and path source gems appear in CHECKSUMS without a hash:
      #   errgonomic (0.5.1)
      #   hello_gem (0.1.0)
      # Return null for these; the caller filters them out.
      # GEM-sourced gems always have 3+ parts: NAME (VERSION) sha256=DIGEST
      isHashless = numParts < 3;

      _ =
        if !isHashless && builtins.elemAt parts 0 == "" then
          throw "gems4nix (internal): parseChecksumLine: unexpected leading whitespace in line: ${line}"
        else
          true;

      gemName = builtins.elemAt parts 0;
      rawVersion = builtins.elemAt parts 1;

      __ =
        if !isHashless && !(lib.strings.hasPrefix "(" rawVersion) then
          throw "gems4nix (internal): parseChecksumLine: expected version in parens, e.g. '(1.0.0)', but got '${rawVersion}' in line: ${line}"
        else
          true;

      # Parse version-platform from the right to handle pre-release versions
      # containing `-` (e.g., `1.0.0-beta.1-arm64-darwin`).
      versionPlatformRaw = lib.strings.removeSuffix ")" (lib.strings.removePrefix "(" rawVersion);
      vp = splitVersionPlatform versionPlatformRaw;
      inherit (vp) version platform;

      rawHash = builtins.elemAt parts 2;
      hashParts = lib.splitString "=" rawHash;

      ___ =
        if !isHashless && builtins.length hashParts < 2 then
          throw "gems4nix (internal): parseChecksumLine: expected 'sha256=DIGEST' but got '${rawHash}' in line: ${line}"
        else
          true;

      sha256 = builtins.elemAt hashParts 1;
    in
    # Git/path gems without a hash: return null (skipped by caller)
    if isHashless then
      null
    else
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

  # ── dependency graph parsing ─────────────────────────────────

  # Parse the dependency graph from raw GEM section lines.
  # Operates on the raw lines (preserving indentation) rather than
  # parseGemSection's output (which discards indentation).
  #
  # In a Gemfile.lock GEM section, after "specs:", gems are at 4-space
  # indent and their dependencies are at 6-space indent:
  #
  #     nokogiri (1.19.2)
  #       mini_portile2 (~> 2.8.2)
  #       racc (~> 1.4)
  #     racc (1.8.1)
  #
  # Returns: { gemName = [ "dep1" "dep2" ... ]; ... }
  # Gem names from the 4-space lines have their version-platform stripped.
  # Dependency names from the 6-space lines have version constraints stripped.
  # Multiple platform variants of the same gem are merged (union of deps).
  parseDependencies =
    lines:
    let
      # Process only lines after "specs:" header
      specsIdx = lib.lists.findFirstIndex (l: lib.strings.hasInfix "specs:" l) null lines;
      specLines = if specsIdx != null then lib.lists.drop (specsIdx + 1) lines else [ ];

      # Walk through spec lines, tracking current gem name and collecting deps.
      # 4-space indent = gem line, 6-space indent = dependency line.
      parsed =
        builtins.foldl'
          (
            acc: line:
            let
              is4space = lib.strings.hasPrefix "    " line && !(lib.strings.hasPrefix "      " line);
              is6space = lib.strings.hasPrefix "      " line;
            in
            if is4space then
              let
                # Extract gem name (first token after stripping whitespace)
                stripped = lib.strings.removePrefix "    " line;
                nameParts = builtins.filter (s: s != "") (lib.strings.splitString " " stripped);
                name = builtins.elemAt nameParts 0;
              in
              acc
              // {
                currentGem = name;
                result = acc.result // {
                  ${name} = (acc.result.${name} or [ ]);
                };
              }
            else if is6space && acc.currentGem != null then
              let
                # Extract dependency name (first token, ignoring version constraint)
                stripped = lib.strings.removePrefix "      " line;
                nameParts = builtins.filter (s: s != "") (lib.strings.splitString " " stripped);
                depName = builtins.elemAt nameParts 0;
                existing = acc.result.${acc.currentGem} or [ ];
                # Merge: avoid duplicates (multiple platform variants of same gem)
                newDeps = if builtins.elem depName existing then existing else existing ++ [ depName ];
              in
              acc
              // {
                result = acc.result // {
                  ${acc.currentGem} = newDeps;
                };
              }
            else
              acc
          )
          {
            currentGem = null;
            result = { };
          }
          specLines;
    in
    parsed.result;

  # Parse the DEPENDENCIES section from a lockfile to get the list of
  # top-level gems (what the user explicitly depends on).
  # Each line is "  gemName" or "  gemName (~> 1.0)" -- extract just the name.
  # Returns: [ "gem1" "gem2" ... ]
  parseDependenciesSection =
    lines:
    builtins.map (
      line:
      let
        stripped = lib.strings.removePrefix "  " line;
        nameParts = builtins.filter (s: s != "") (lib.strings.splitString " " stripped);
      in
      builtins.elemAt nameParts 0
    ) lines;

  # Extract the DEPENDENCIES section lines from a lockfile's raw lines.
  # Returns: list of lines between DEPENDENCIES header and next blank line.
  takeDependenciesSection =
    lines:
    let
      idx = lib.lists.findFirstIndex (l: l == "DEPENDENCIES") null lines;
    in
    if idx != null then takeLines idx lines else [ ];

  # ── lockfile-level assembly (pure, no IO) ────────────────────

  # Parse the full content of a Gemfile.lock into its checksum and GEM sections.
  # Returns: { checksumSection, gemSections }
  parseLockfile =
    content:
    let
      lines = lib.splitString "\n" content;

      # CHECKSUMS
      checksumSectionIndex = lib.lists.findFirstIndex (line: line == "CHECKSUMS") null lines;
      checksumSectionLines =
        if checksumSectionIndex == null then
          throw "gems4nix: cannot find CHECKSUMS in Gemfile.lock - run 'bundle lock --add-checksums'"
        else
          takeLines checksumSectionIndex lines;
      # parseChecksumLine returns null for git/path gems (no hash); filter them out.
      checksumSection = builtins.filter (x: x != null) (
        lib.lists.map parseChecksumLine checksumSectionLines
      );

      # GEM sections (may have more than one remote)
      gemSectionIndices = findIndices (l: l == "GEM") lines;
      _ =
        if gemSectionIndices == [ ] then
          throw "gems4nix: cannot find GEM section in Gemfile.lock - is this a valid Bundler lockfile?"
        else
          true;
      gemSectionLines = lib.lists.map (i: takeLines i lines) gemSectionIndices;
      gemSections = lib.lists.map parseGemSection gemSectionLines;
    in
    assert _ == true;
    {
      inherit checksumSection gemSections;
    };

  # Invert gem sections into a flat { gemName = remote; ... } lookup.
  # First-writer-wins when a gem appears in multiple sections (builtins.listToAttrs
  # keeps the first entry for duplicate keys).
  # TODO: group by gem name for multiple remotes; e.g., depot depends on faraday
  # which shows up in both but we prefer rubygems.org.
  indexRemotes =
    gemSections:
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
  mergeGemMetadata =
    {
      checksumSection,
      gemRemotes,
      gemGroups,
    }:
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
    knownPlatforms
    splitVersionPlatform
    parseChecksumLine
    parseGemSection
    parseDependencies
    parseDependenciesSection
    takeDependenciesSection
    parseLockfile
    indexRemotes
    mergeGemMetadata
    ;
}

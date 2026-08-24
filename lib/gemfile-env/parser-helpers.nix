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

  # Parse the "NAME (VERSION[-PLATFORM])" part of a spec or checksum line.
  #   "    errgonomic (0.5.1)"        -> version "0.5.1",  platform "ruby"
  #   "    ffi (1.17.3-arm64-darwin)" -> version "1.17.3", platform "arm64-darwin"
  #
  # This ignores leading spaces. Callers that need the indent depth must check
  # it first. The version ends at the first hyphen and the platform is the
  # rest, which is how Bundler itself splits the two.
  parseSpecLine =
    line:
    let
      parts = builtins.filter (s: s != "") (lib.strings.splitString " " line);
      rawVersion = builtins.elemAt parts 1;

      _ =
        if builtins.length parts < 2 then
          throw "parseSpecLine: expected 'NAME (VERSION)' in line: ${line}"
        else if !(lib.strings.hasPrefix "(" rawVersion) then
          throw "parseSpecLine: expected version in parens, e.g. '(1.0.0)', but got '${rawVersion}' in line: ${line}"
        else
          true;

      versionParts = lib.strings.splitString "-" (
        lib.strings.removeSuffix ")" (lib.strings.removePrefix "(" rawVersion)
      );
    in
    assert _ == true;
    {
      gemName = builtins.elemAt parts 0;
      version = builtins.elemAt versionParts 0;
      platform =
        if builtins.length versionParts > 1 then
          lib.strings.concatStringsSep "-" (lib.lists.drop 1 versionParts)
        else
          "ruby";
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
          throw "parseChecksumLine: unexpected leading whitespace in line: ${line}"
        else
          true;

      # the same NAME (VERSION) shape that GIT and PATH spec lines use
      spec = parseSpecLine line;

      rawHash = builtins.elemAt parts 2;
      hashParts = lib.splitString "=" rawHash;

      __ =
        if !isHashless && builtins.length hashParts < 2 then
          throw "parseChecksumLine: expected 'sha256=DIGEST' but got '${rawHash}' in line: ${line}"
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
      {
        inherit (spec)
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

  # ── GIT / PATH sections ──────────────────────────────────────

  # Split the body of a GIT or PATH section into its options and its gems.
  #
  # Bundler indents by 2, 4 or 6 spaces, and the depth is the only thing that
  # gives a line its meaning:
  #
  #   2 spaces   an option, such as `remote:`
  #   4 spaces   a gem this source provides
  #   6 spaces   a dependency of the gem above it, provided by some other source
  #
  # A 6-space line names a gem that this source does not contain. Count the
  # spaces, or such a line becomes a gem that nothing can build.
  #
  # Returns: { headers = { remote = "..."; ... }; specLines = [ ... ]; hasSpecs = bool; }
  parseSectionBody =
    lines:
    let
      step =
        acc: line:
        if line == "  specs:" then
          acc
          // {
            inSpecs = true;
            hasSpecs = true;
          }
        else if acc.inSpecs then
          if builtins.match "    ([^ ].*)" line != null then
            acc // { specLines = acc.specLines ++ [ line ]; }
          else if builtins.match "      +[^ ].*" line != null then
            acc # 6-space dependency line: not a gem of this source
          else
            throw "parseSectionBody: unexpected line inside specs: '${line}'"
        else
          let
            m = builtins.match "  ([a-zA-Z]+):[ ]?(.*)" line;
            key = builtins.elemAt m 0;
          in
          if m == null then
            throw "parseSectionBody: expected '  key: value' but got '${line}'"
          else if acc.headers ? ${key} then
            throw "parseSectionBody: repeated option '${key}' in a GIT/PATH section"
          else
            acc
            // {
              headers = acc.headers // {
                ${key} = builtins.elemAt m 1;
              };
            };

      result = builtins.foldl' step {
        headers = { };
        specLines = [ ];
        inSpecs = false;
        hasSpecs = false;
      } lines;
    in
    {
      inherit (result) headers specLines hasSpecs;
    };

  # Options we understand in a GIT section. An unknown option is an error,
  # because most options change which files the gem is built from. To ignore
  # one is to build the wrong thing.
  gitSectionKeys = [
    "remote"
    "revision"
    "ref"
    "branch"
    "tag"
    "submodules"
  ];

  # Shared validation for GIT and PATH sections.
  validateSection =
    {
      kind,
      body,
      allowedKeys,
    }:
    let
      h = body.headers;
      unknown = builtins.filter (k: !(builtins.elem k allowedKeys)) (builtins.attrNames h);
    in
    if !body.hasSpecs then
      throw "gems4nix: ${kind} section has no 'specs:' line"
    else if h ? glob then
      # `glob:` selects one gemspec out of several in a repository.
      # buildRubyGem always takes the first gemspec it finds, so it cannot obey
      # a glob, and it would build the wrong gem without saying so.
      throw
        "gems4nix: ${kind} sources with a 'glob:' option are not supported (remote: ${h.remote or "?"})"
    else if unknown != [ ] then
      throw "gems4nix: unsupported key '${builtins.head unknown}' in ${kind} section"
    else if !(h ? remote) then
      throw "gems4nix: ${kind} section has no 'remote:'"
    else
      h;

  # GIT section -> { remote; revision; ref; branch; tag; submodules; gems; }
  parseGitSection =
    lines:
    let
      body = parseSectionBody lines;
      h = validateSection {
        kind = "GIT";
        inherit body;
        allowedKeys = gitSectionKeys;
      };
    in
    if !(h ? revision) then
      throw "gems4nix requires a pinned revision: the GIT section for '${h.remote}' has no 'revision:'"
    else
      {
        inherit (h) remote revision;
        ref = h.ref or null;
        branch = h.branch or null;
        tag = h.tag or null;
        # Compare against "true" by hand. The value here is a string, and the
        # string "false" is not false.
        submodules = (h.submodules or "false") == "true";
        gems = lib.lists.map parseSpecLine body.specLines;
      };

  # PATH section -> { remote; gems; }
  parsePathSection =
    lines:
    let
      body = parseSectionBody lines;
      h = validateSection {
        kind = "PATH";
        inherit body;
        allowedKeys = [ "remote" ];
      };
    in
    # `seq` makes the checks above run as soon as anyone looks at the result.
    # Without it they wait for a caller to read `remote`, and a bad section can
    # pass through unchecked.
    builtins.seq h {
      inherit (h) remote;
      gems = lib.lists.map parseSpecLine body.specLines;
    };

  # ── lockfile-level assembly (pure, no IO) ────────────────────

  # Parse the full content of a Gemfile.lock into its checksum, GEM, GIT and
  # PATH sections.
  # Returns: { checksumSection, gemSections, gitSections, pathSections }
  parseLockfileContent =
    content:
    let
      lines = lib.splitString "\n" content;

      # CHECKSUMS
      checksumSectionIndex = lib.lists.findFirstIndex (line: line == "CHECKSUMS") null lines;
      checksumSectionLines =
        if checksumSectionIndex == null then
          throw "cannot find CHECKSUMS in Gemfile.lock - run 'bundle lock --add-checksums'"
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
          throw "cannot find GEM section in Gemfile.lock - is this a valid Bundler lockfile?"
        else
          true;
      gemSectionLines = lib.lists.map (i: takeLines i lines) gemSectionIndices;
      gemSections = lib.lists.map parseGemSection gemSectionLines;

      # Keep these out of buildGemRemotes. It keeps the first remote it sees
      # for a gem, and Bundler writes GIT and PATH sections before GEM ones. An
      # entry that leaked in would replace a gem's real rubygems.org remote.
      gitSections = lib.lists.map (i: parseGitSection (takeLines i lines)) (
        findIndices (l: l == "GIT") lines
      );
      pathSections = lib.lists.map (i: parsePathSection (takeLines i lines)) (
        findIndices (l: l == "PATH") lines
      );

      __ =
        if findIndices (l: l == "PLUGIN SOURCE") lines != [ ] then
          throw "gems4nix: PLUGIN SOURCE sections are not supported"
        else
          true;

      # A CHECKSUMS entry with no hash comes from a GIT or PATH section. If no
      # such section claims it, we cannot build it, and the user learns this
      # from a LoadError long afterwards. Fail here instead.
      #
      # Names are enough to match on. Bundler never writes a version here that
      # disagrees with the source section.
      sourcedNames = lib.lists.map (g: g.gemName) (
        lib.lists.concatMap (s: s.gems) (gitSections ++ pathSections)
      );
      unexplained = builtins.filter (n: !(builtins.elem n sourcedNames)) (
        lib.lists.map (l: (parseSpecLine l).gemName) (
          builtins.filter (l: l != "" && parseChecksumLine l == null) checksumSectionLines
        )
      );
      ___ =
        if unexplained != [ ] then
          throw "gems4nix: '${builtins.head unexplained}' has no checksum and no GIT/PATH source in the lockfile"
        else
          true;
    in
    assert _ == true;
    assert __ == true;
    assert ___ == true;
    {
      inherit
        checksumSection
        gemSections
        gitSections
        pathSections
        ;
    };

  # Invert gem sections into a flat { gemName = remote; ... } lookup.
  # Last-writer-wins when a gem appears in multiple sections.
  # TODO: group by gem name for multiple remotes; e.g., depot depends on faraday
  # which shows up in both but we prefer rubygems.org.
  buildGemRemotes =
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
      gitSections ? [ ],
      pathSections ? [ ],
      pathRoot ? null,
    }:
    let
      # Build-time deps (e.g., mini_portile2) may appear in the lock but not
      # in the group parser output. Default to empty groups so they get
      # filtered out rather than crashing.
      groupsFor = gemName: gemGroups.${gemName} or [ ];

      gemFromChecksums = lib.lists.map (gemAttrs: {
        inherit (gemAttrs)
          gemName
          platform
          version
          ;
        groups = groupsFor gemAttrs.gemName;
        source = gemAttrs.source // {
          remotes = [ gemRemotes.${gemAttrs.gemName} ];
          type = "gem";
        };
      }) checksumSection;

      gemFromGit = lib.lists.concatMap (
        section:
        lib.lists.map (gem: {
          inherit (gem)
            gemName
            platform
            version
            ;
          groups = groupsFor gem.gemName;
          source = {
            type = "git";
            url = section.remote;
            rev = section.revision;
            # nixpkgs calls this fetchSubmodules in its gemset.nix files. Use
            # the same name, so we can emit that format later without a rename.
            fetchSubmodules = section.submodules;
            # We keep these but never fetch by them. The revision alone
            # decides which source we get: a fetch that adds a ref or a branch
            # returns the identical store path. They are here to describe the
            # source, not to find it.
            inherit (section) ref branch tag;
          };
        }) section.gems
      ) gitSections;

      gemFromPath = lib.lists.concatMap (
        section:
        lib.lists.map (gem: {
          inherit (gem)
            gemName
            platform
            version
            ;
          groups = groupsFor gem.gemName;
          source = {
            type = "path";
            # Add the whole suffix in one step. Nix resolves "." and ".."
            # only when it joins a path to a complete string, so a remote of
            # "." or "../shared" needs this form. Two steps, as in
            # (pathRoot + "/") + remote, leave a literal "/." in the path.
            path = pathRoot + "/${section.remote}";
          };
        }) section.gems
      ) pathSections;

      sourced = gemFromGit ++ gemFromPath;
      sourcedNames = lib.lists.map (g: g.gemName) sourced;
      checksumNames = lib.lists.map (g: g.gemName) checksumSection;

      # A name repeats inside checksumSection once per platform, which is
      # correct. A git or path gem is one build, so its name must appear once.
      # Two sources for one name means we cannot tell which the user wants.
      collisions =
        builtins.filter (n: builtins.elem n checksumNames) sourcedNames
        ++ builtins.attrNames (
          lib.attrsets.filterAttrs (_: v: builtins.length v > 1) (builtins.groupBy (n: n) sourcedNames)
        );

      _ =
        if pathSections != [ ] && pathRoot == null then
          throw "gems4nix: the lockfile has PATH sources but no root to resolve them against; pass `root` to gemfileEnv"
        else if collisions != [ ] then
          throw "gems4nix: '${builtins.head collisions}' is declared by more than one source in the lockfile"
        else
          true;
    in
    assert _ == true;
    gemFromChecksums ++ sourced;

in
{
  inherit
    findIndices
    takeLines
    parseSpecLine
    parseChecksumLine
    parseGemSection
    parseSectionBody
    parseGitSection
    parsePathSection
    parseLockfileContent
    buildGemRemotes
    mergeGemMetadata
    ;
}

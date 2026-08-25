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

  # Parse the "NAME (VERSION[-PLATFORM])" part of a spec or checksum line.
  #   "    errgonomic (0.5.1)"        -> version "0.5.1",  platform "ruby"
  #   "    ffi (1.17.3-arm64-darwin)" -> version "1.17.3", platform "arm64-darwin"
  #
  # Leading spaces are ignored. Callers that need the indent depth must check
  # it themselves before calling.
  parseSpecLine =
    line:
    let
      parts = builtins.filter (s: s != "") (lib.strings.splitString " " line);
      rawVersion = builtins.elemAt parts 1;

      _ =
        if builtins.length parts < 2 then
          throw "gems4nix (internal): parseSpecLine: expected 'NAME (VERSION)' in line: ${line}"
        else if !(lib.strings.hasPrefix "(" rawVersion) then
          throw "gems4nix (internal): parseSpecLine: expected version in parens, e.g. '(1.0.0)', but got '${rawVersion}' in line: ${line}"
        else
          true;

      vp = splitVersionPlatform (lib.strings.removeSuffix ")" (lib.strings.removePrefix "(" rawVersion));
    in
    assert _ == true;
    {
      inherit (vp) version platform;
      gemName = builtins.elemAt parts 0;
    };

  # parse a gem checksum line
  # "  zeitwerk (2.6.18) sha256=bd2d213996ff7b3b364cd342a585fbee9797dbc1c0c6d868dc4150cc75739781"
  parseChecksumLine =
    line:
    let
      stripped = lib.strings.removePrefix "  " line;
      # Empty tokens are dropped, so this indexes the same way parseSpecLine
      # does. Two functions splitting one line two ways report the wrong
      # problem: a doubled space between name and version used to come back as
      # a complaint about the hash.
      parts = builtins.filter (s: s != "") (lib.strings.splitString " " stripped);
      numParts = builtins.length parts;

      # Git and path source gems appear in CHECKSUMS without a hash:
      #   errgonomic (0.5.1)
      #   hello_gem (0.1.0)
      # Return null for these; the caller filters them out.
      # GEM-sourced gems always have 3+ parts: NAME (VERSION) sha256=DIGEST
      isHashless = numParts < 3;

      # A CHECKSUMS entry is indented exactly two spaces. Anything deeper is a
      # line from some other section, which means the caller sliced the wrong
      # block. Filtering the tokens above hides that, so check the raw text.
      _ =
        if lib.strings.hasPrefix " " stripped then
          throw "gems4nix (internal): parseChecksumLine: unexpected leading whitespace in line: ${line}"
        else
          true;

      # A checksum line opens with the same NAME (VERSION) shape a GIT or PATH
      # spec line uses.
      spec = parseSpecLine line;

      rawHash = builtins.elemAt parts 2;
      hashParts = lib.splitString "=" rawHash;

      __ =
        if !isHashless && builtins.length hashParts < 2 then
          throw "gems4nix (internal): parseChecksumLine: expected 'sha256=DIGEST' but got '${rawHash}' in line: ${line}"
        else
          true;

      sha256 = builtins.elemAt hashParts 1;
    in
    # Git/path gems without a hash: return null (skipped by caller)
    if isHashless then
      assert _ == true;
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

  # ── GIT / PATH sections ──────────────────────────────────────

  # Split the body of a GIT or PATH section into its options and its gems.
  #
  # Bundler indents by 2, 4 or 6 spaces, and the depth is the only thing that
  # gives a line its meaning:
  #
  #   2 spaces   an option, such as `remote:`
  #   4 spaces   a gem this source provides
  #   6 spaces   a dependency of the gem above it
  #
  # A 6-space line names a dependency, not a gem to build from this section.
  # Count the spaces, or such a line becomes a gem that nothing can build.
  #
  # A key in `repeatable` collects its values into a list, in the order the
  # lockfile writes them. Every other key holds a single string and a repeat
  # throws, because two answers to a question with one answer cannot be merged.
  #
  # Returns: { headers = { remote = "..."; ... }; specLines = [ ... ]; hasSpecs = bool; }
  parseSectionBody =
    {
      lines,
      repeatable ? [ ],
    }:
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
            throw "gems4nix: unexpected line inside a lockfile source's specs: '${line}'"
        else
          let
            m = builtins.match "  ([a-zA-Z_]+):[ ]?(.*)" line;
          in
          if m == null then
            throw "gems4nix: expected '  key: value' in a lockfile source section but got '${line}'"
          else
            let
              key = builtins.elemAt m 0;
              value = builtins.elemAt m 1;
            in
            if builtins.elem key repeatable then
              acc
              // {
                headers = acc.headers // {
                  ${key} = (acc.headers.${key} or [ ]) ++ [ value ];
                };
              }
            else if acc.headers ? ${key} then
              throw "gems4nix: repeated option '${key}' in a lockfile source section"
            else
              acc
              // {
                headers = acc.headers // {
                  ${key} = value;
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

  # A GEM section names the remotes its gems come from, and the gems it
  # provides. Versions come from CHECKSUMS, so only the names matter here.
  #
  # Bundler puts several `remote:` lines in one GEM section when a Gemfile
  # declares more than one global source, and writes them last-declared-first,
  # which is its own source-priority order. Keeping the lockfile's order means
  # a fetch tries them in that order too.
  #
  # Only the 4-space lines are gems of this section. A 6-space line names a
  # dependency, which some other section may well provide; counting it here
  # claims this section's remote for a gem that is not on it.
  parseGemSection =
    lines:
    let
      body = parseSectionBody {
        inherit lines;
        repeatable = [ "remote" ];
      };
      h = body.headers;
      unknown = builtins.filter (k: k != "remote") (builtins.attrNames h);
      remotes = lib.lists.map (lib.strings.removeSuffix "/") (h.remote or [ ]);
    in
    if !body.hasSpecs then
      throw "gems4nix: GEM section has no 'specs:' line"
    else if unknown != [ ] then
      throw "gems4nix: unsupported key '${builtins.head unknown}' in GEM section"
    else if remotes == [ ] then
      throw "gems4nix: GEM section has no 'remote:'"
    else
      {
        inherit remotes;
        # A name repeats once per locked platform, and every variant is on the
        # same remote, so one entry per name says everything.
        gems = lib.unique (lib.lists.map (l: (parseSpecLine l).gemName) body.specLines);
      };

  # Options we recognise in a GIT section. An unrecognised option is an error,
  # because most options change which files the gem is built from. To ignore
  # one is to build the wrong thing.
  #
  # `glob` is recognised and then refused, which is why it is listed here.
  # Leaving it out would let the unrecognised-key branch reject it, and the
  # message that branch gives does not say why a glob in particular cannot
  # work.
  gitSectionKeys = [
    "remote"
    "revision"
    "ref"
    "branch"
    "tag"
    "submodules"
    "glob"
  ];

  # A PATH section has no revision to pin, so it takes only its remote — and
  # `glob`, on the same recognise-then-refuse footing as GIT.
  pathSectionKeys = [
    "remote"
    "glob"
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
      # `glob:` selects one gemspec out of several in a repository. buildRubyGem
      # always takes the first gemspec it finds, so it cannot obey a glob, and
      # it would build the wrong gem without saying so.
      throw
        "gems4nix: ${kind} sources with a 'glob:' option are not supported (remote: ${h.remote or "?"})"
    else if unknown != [ ] then
      throw "gems4nix: unsupported key '${builtins.head unknown}' in ${kind} section (remote: ${h.remote or "?"})"
    else if !(h ? remote) then
      throw "gems4nix: ${kind} section has no 'remote:'"
    else
      h;

  # GIT section -> { remote; revision; ref; branch; tag; submodules; gems; }
  parseGitSection =
    lines:
    let
      body = parseSectionBody { inherit lines; };
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
      body = parseSectionBody { inherit lines; };
      h = validateSection {
        kind = "PATH";
        inherit body;
        allowedKeys = pathSectionKeys;
      };
    in
    # `seq` makes the checks above run as soon as anyone looks at the result.
    # Without it they wait for a caller to read `remote`, and a bad section can
    # pass through unchecked.
    builtins.seq h {
      inherit (h) remote;
      gems = lib.lists.map parseSpecLine body.specLines;
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

  # Parse the full content of a Gemfile.lock into its checksum, GEM, GIT and
  # PATH sections.
  # Returns: { checksumSection, gemSections, gitSections, pathSections }
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

      # Keep these out of indexRemotes. It keeps the first remote it sees for a
      # gem, and Bundler writes GIT and PATH sections before GEM ones. An entry
      # that leaked in would replace a gem's real rubygems.org remote.
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

  # Invert gem sections into a flat { gemName = [ remote ... ]; } lookup. A gem
  # gets every remote of the section that provides it, because any of them may
  # serve it and the lockfile's order is Bundler's priority order.
  #
  # Two sections claiming one gem is not a lockfile Bundler writes: it locks a
  # resolved spec under the single source that resolved it. There is also no
  # rule that would say which one wins, and Bundler does not invent one — it
  # tells the user to name the source in the Gemfile. Do the same rather than
  # taking whichever section came first, which reads as a decision and is not.
  indexRemotes =
    gemSections:
    let
      entries = lib.lists.concatMap (
        section:
        lib.lists.map (gem: {
          name = gem;
          value = section.remotes;
        }) section.gems
      ) gemSections;

      claimed = builtins.groupBy (e: e.name) entries;
      contested = builtins.attrNames (lib.attrsets.filterAttrs (_: v: builtins.length v > 1) claimed);
    in
    if contested != [ ] then
      let
        gemName = builtins.head contested;
        remotes = lib.lists.concatMap (e: e.value) claimed.${gemName};
      in
      throw "gems4nix: '${gemName}' is provided by more than one GEM section in the lockfile (${lib.concatStringsSep ", " remotes}); add it to the source block for the remote you want it from and relock"
    else
      builtins.listToAttrs entries;

  # Merge parsed checksums with group info and remote URLs into the final
  # gem metadata list that the rest of the pipeline expects.
  #
  # Gems from GIT and PATH sections join the same list. They carry no checksum,
  # so their `source` describes where to get them instead of how to verify a
  # downloaded archive.
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
          remotes =
            gemRemotes.${gemAttrs.gemName}
              or (throw "gems4nix: '${gemAttrs.gemName}' has a checksum but no GEM section provides it");
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
            # Recorded, never fetched by. The revision alone decides which
            # source we get: a fetch that adds a ref or a branch returns the
            # identical store path. These describe the source, not find it.
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
            # Add the whole suffix in one step. Nix resolves "." and ".." only
            # when it joins a path to a complete string, so a remote of "." or
            # "../shared" needs this form. Two steps, as in
            # (pathRoot + "/") + remote, do not work: Nix drops the trailing
            # slash first, so "." gives the sibling path /tmp/fixture.
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
    knownPlatforms
    splitVersionPlatform
    parseSpecLine
    parseChecksumLine
    parseGemSection
    parseSectionBody
    parseGitSection
    parsePathSection
    parseDependencies
    parseDependenciesSection
    takeDependenciesSection
    parseLockfile
    indexRemotes
    mergeGemMetadata
    ;
}

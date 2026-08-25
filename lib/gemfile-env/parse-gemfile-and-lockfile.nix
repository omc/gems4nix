# IO shell: reads files, runs Ruby for group info, delegates pure logic to
# parse.nix. All testable logic lives there.
#
# ── Impurity note: gem group extraction ─────────────────────
# Group extraction (mapping gems to Gemfile groups like :default, :test, etc.)
# uses Ruby IFD (import-from-derivation) via gem-groups.rb. This spawns a
# Bundler process at eval time to inspect the Gemfile's group declarations.
#
# This is acceptable because:
# - Gemfile semantics are tightly coupled to Bundler: groups can be defined
#   with arbitrary Ruby (conditionals, eval, method calls) that only Bundler
#   can reliably interpret.
# - The IFD is hermetic: it reads only the Gemfile and Gemfile.lock, runs in
#   a sandboxed derivation, and produces deterministic JSON output.
#
# Users who want to avoid the IFD can supply the `gemGroups` parameter to
# gemfileEnv with an explicit { gemName = [ "group1" "group2" ]; ... }
# mapping. When gemGroups is non-null, gem-groups.rb is skipped entirely.
#
# A pure Nix Gemfile parser is a long-term aspiration but impractical for
# general use given the arbitrary Ruby that real Gemfiles contain.
# ─────────────────────────────────────────────────────────────
#
# callPackage definitions:
{
  lib,
  runCommand,
  ruby,
  bundler,
  git,
  fetchurl,
  stdenv,
  defaultGemConfig,
  buildRubyGem,
  callPackage,
  ...
}:

# function arguments:
{
  gemfile,
  gemfileLock,
  gemGroups ? null, # null = auto-detect via gem-groups.rb; attrset = override
  gemspec ? null, # path to *.gemspec when the Gemfile uses the `gemspec` directive
  extraFiles ? { }, # { "relative/dest" = ./src; } — files the gemspec require_relatives
  # Directory that PATH `remote:` values resolve against. Bundler writes them
  # relative to the Gemfile, so that is the default.
  root ? null,
}:

let

  helpers = import ./parse.nix { inherit lib; };
  inherit (helpers)
    parseLockfile
    indexRemotes
    mergeGemMetadata
    parseDependencies
    ;

  # ── IO ───────────────────────────────────────────────────────

  # Detect the Bundler `gemspec` directive in the Gemfile. When present, the
  # group-detection IFD sandbox must include the gemspec (and anything it
  # require_relatives) or Bundler aborts with `Bundler::InvalidOption: There
  # are no gemspecs`. See github.com/omc/gems4nix issue #2.
  gemfileText = builtins.readFile gemfile;
  gemfileUsesGemspec =
    let
      isGemspecLine = line: builtins.match "[[:space:]]*gemspec([[:space:]#(].*)?" line != null;
    in
    lib.any isGemspecLine (lib.splitString "\n" gemfileText);

  needsGemspecButMissing = gemfileUsesGemspec && gemspec == null && gemGroups == null;

  gemspecError = throw ''
    gems4nix: Gemfile uses the `gemspec` directive but no gemspec was supplied.

    Bundler needs the .gemspec (and any files it require_relatives) available
    at group-detection time. Add these arguments to your gemfileEnv call:

        gemspec    = ./<your-name>.gemspec;
        extraFiles = { "lib/<your-name>/version.rb" = ./lib/<your-name>/version.rb; };

    Alternatively, pass an explicit `gemGroups = { ... }` mapping to skip
    Bundler group inference entirely.
  '';

  # Copy the caller-supplied gemspec into the sandbox as `project.gemspec`.
  # The filename doesn't matter to Bundler — it globs `*.gemspec` — but the
  # gemspec's require_relative calls resolve from the sandbox root, so
  # extraFiles must land at their declared destinations.
  copyGemspecCmd = lib.optionalString (gemspec != null) ''
    cp ${gemspec} project.gemspec
  '';

  copyExtraFilesCmd = lib.concatMapStringsSep "\n" (dest: ''
    mkdir -p "$(dirname ${lib.escapeShellArg dest})"
    cp ${extraFiles.${dest}} ${lib.escapeShellArg dest}
  '') (builtins.attrNames extraFiles);

  # use the Gemfile to produce group information for each gem
  # (skipped when the caller supplies an explicit gemGroups override)
  gemGroupsJson =
    if needsGemspecButMissing then
      gemspecError
    else
      runCommand "gem-groups-json"
        {
          # git is needed because the canonical `bundle gem` gemspec computes
          # spec.files via `IO.popen(%w[git ls-files -z])`. Without git on PATH
          # that popen raises Errno::ENOENT and gemspec evaluation aborts.
          buildInputs = [
            ruby
            bundler
            git
          ];
        }
        ''
          cp ${gemfile} Gemfile
          cp ${gemfileLock} Gemfile.lock
          ${copyGemspecCmd}
          ${copyExtraFilesCmd}
          ruby ${./gem-groups.rb} > $out
        '';

  # ── pure assembly (delegated to helpers) ─────────────────────

  content = builtins.readFile gemfileLock;
  lines = lib.splitString "\n" content;
  parsed = parseLockfile content;
  gemRemotes = indexRemotes parsed.gemSections;

  pathRoot = if root != null then root else builtins.dirOf gemfile;

  # Check the directories now. A missing one reported here can name `root` and
  # say what to do. The same mistake found later, inside buildRubyGem, appears
  # as an unpack error that explains nothing.
  pathSections = lib.lists.map (
    section:
    let
      resolved = pathRoot + "/${section.remote}";
    in
    if builtins.pathExists resolved then
      section
    else
      throw "gems4nix: PATH source '${section.remote}' does not exist at ${toString resolved}. Pass `root` to gemfileEnv if the Gemfile is not co-located with its path gems."
  ) parsed.pathSections;

  resolvedGemGroups =
    if gemGroups != null then gemGroups else builtins.fromJSON (builtins.readFile gemGroupsJson);

  # Build the dependency graph from every section that has a `specs:` block.
  # parseDependencies operates on raw lines (preserving indentation), and a
  # GIT or PATH block is indented exactly like a GEM one. Sections are merged;
  # entries for the same gem name merge their dep lists.
  specSectionIndices = helpers.findIndices (l: l == "GEM" || l == "GIT" || l == "PATH") lines;
  specSectionRawLines = lib.lists.map (i: helpers.takeLines i lines) specSectionIndices;
  depGraphs = lib.lists.map parseDependencies specSectionRawLines;
  depGraph = builtins.foldl' (
    acc: g: lib.attrsets.zipAttrsWith (name: vals: lib.unique (lib.flatten vals)) ([ acc ] ++ [ g ])
  ) { } depGraphs;

in
{
  gems = mergeGemMetadata {
    inherit (parsed) checksumSection gitSections;
    inherit gemRemotes pathSections pathRoot;
    gemGroups = resolvedGemGroups;
  };
  inherit depGraph;
  # Null unless the lockfile names a Ruby. Which Ruby the environment is
  # actually built with is gemfileEnv's argument, not this module's, so the
  # comparison belongs there.
  inherit (parsed) rubyVersion;
}

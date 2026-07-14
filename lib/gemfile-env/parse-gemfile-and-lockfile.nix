# TODO: git source
#
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
          buildInputs = [
            ruby
            bundler
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
  resolvedGemGroups =
    if gemGroups != null then gemGroups else builtins.fromJSON (builtins.readFile gemGroupsJson);

  # Build the dependency graph from all GEM sections.
  # parseDependencies operates on raw lines (preserving indentation).
  # Multiple GEM sections (multiple remotes) are merged; later entries
  # for the same gem name merge their dep lists.
  gemSectionIndices = helpers.findIndices (l: l == "GEM") lines;
  gemSectionRawLines = lib.lists.map (i: helpers.takeLines i lines) gemSectionIndices;
  depGraphs = lib.lists.map parseDependencies gemSectionRawLines;
  depGraph = builtins.foldl' (
    acc: g: lib.attrsets.zipAttrsWith (name: vals: lib.unique (lib.flatten vals)) ([ acc ] ++ [ g ])
  ) { } depGraphs;

in
{
  gems = mergeGemMetadata {
    inherit (parsed) checksumSection;
    inherit gemRemotes;
    gemGroups = resolvedGemGroups;
  };
  inherit depGraph;
}

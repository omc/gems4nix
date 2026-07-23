# Pure helper functions for filtering and resolving gems.
# No nixpkgs build dependencies, only lib.
{ lib }:

{
  # Keep gems whose groups overlap with the requested groups.
  # Returns true if the gem should be included.
  filterGroup = groups: gem: builtins.length (lib.lists.intersectLists groups gem.groups) > 0;

  # Keep gems whose platform matches one of the requested platforms.
  # Returns true if the gem should be included.
  filterPlatform = platforms: gem: lib.lists.any (p: p == gem.platform) platforms;

  # Apply per-gem configuration overrides from gemConfig.
  # gemConfig is an attrset of { gemName = attrs: { ... }; ... }.
  # If gemConfig has an entry for this gem, call it with the gem's attrs and
  # merge the result. Otherwise return attrs unchanged.
  applyGemConfigs =
    gemConfig: attrs:
    if gemConfig ? ${attrs.gemName} then attrs // gemConfig.${attrs.gemName} attrs else attrs;

  # Expand a set of gem names to include all transitive dependencies.
  # depGraph: { gemName = [ "dep1" "dep2" ... ]; ... } from parseDependencies
  # initialNames: list of gem names that survived group+platform filtering
  # Returns: expanded list of gem names including all transitive deps.
  # Uses a convergent fixpoint: iterates until no new deps are added.
  expandTransitiveDeps =
    depGraph: initialNames:
    let
      step =
        names:
        let
          newDeps = lib.unique (lib.flatten (map (n: depGraph.${n} or [ ]) names));
        in
        lib.unique (names ++ newDeps);
      converge =
        prev:
        let
          next = step prev;
        in
        if next == prev then prev else converge next;
    in
    converge initialNames;

  # Map a nixpkgs system string to the Ruby platform strings that should be
  # accepted from a Gemfile.lock. Always includes "ruby" (pure-Ruby gems).
  #
  # The mapping covers the four systems that RubyGems publishes pre-built
  # native gems for. Musl variants are included for Alpine/NixOS-static.
  # Unknown systems throw with a clear message so users know to override.
  platformsForSystem =
    system:
    let
      mapping = {
        "aarch64-darwin" = [
          "ruby"
          "arm64-darwin"
          "universal-darwin"
        ];
        "x86_64-darwin" = [
          "ruby"
          "x86_64-darwin"
          "universal-darwin"
        ];
        "aarch64-linux" = [
          "ruby"
          "aarch64-linux"
          "aarch64-linux-gnu"
          "aarch64-linux-musl"
        ];
        "x86_64-linux" = [
          "ruby"
          "x86_64-linux"
          "x86_64-linux-gnu"
          "x86_64-linux-musl"
        ];
      };
    in
    if mapping ? ${system} then
      mapping.${system}
    else
      throw "gems4nix: unsupported system '${system}'. Supported: aarch64-darwin, x86_64-darwin, aarch64-linux, x86_64-linux. Or pass an explicit `platforms` list.";

  # Check whether a lockfile has precompiled native gem variants.
  # If the target platforms include non-ruby platforms but NO gem in the
  # parsed lockfile has a non-ruby platform, emit a lib.warn advising the
  # user to add platform variants to their lockfile.
  #
  # gems: flat list of gem attrsets (the full parsed lockfile, before filtering)
  # platforms: resolved platform list (from platformsForSystem or user)
  # Returns: platforms (pass-through), but with a warning attached if needed.
  warnIfNoPlatformGems =
    gems: platforms:
    let
      wantNative = builtins.any (p: p != "ruby") platforms;
      hasNative = builtins.any (g: g.platform != "ruby") gems;
      platformsStr = lib.concatStringsSep " " (builtins.filter (p: p != "ruby") platforms);
    in
    if wantNative && !hasNative then
      lib.warn ''
        gems4nix: Your Gemfile.lock contains no precompiled native gem variants.
        All native gems will be compiled from source, which may be slow or fail.
        To add precompiled variants, run:
          bundle lock --add-platform ${platformsStr}'' platforms
    else
      platforms;

  # Given a preference-ordered platform list and a list of gems (possibly
  # containing duplicates for different platforms), resolve to one gem per
  # name. Candidates are ranked by position in preferredPlatforms,
  # earlier entries win. This means: exact arch match > compatible match
  # (e.g., universal-darwin) > pure ruby.
  #
  # preferredPlatforms: list from platformsForSystem, e.g.,
  #   ["ruby" "arm64-darwin" "universal-darwin"]
  # gems: flat list of gem attrsets (may have duplicate gemNames)
  #
  # Returns: attrset of gemName -> single gem
  resolvePlatforms =
    preferredPlatforms: gems:
    let
      gemsByName = builtins.groupBy (g: g.gemName) gems;

      # Rank a gem by its platform's position in preferredPlatforms.
      # Non-"ruby" platforms are preferred, then by list order within those.
      # Platforms not in the list get a very high rank (filtered out earlier,
      # but defensive).
      rankGem =
        gem:
        let
          idx = lib.lists.findFirstIndex (p: p == gem.platform) 9999 preferredPlatforms;
          # Bias: non-ruby platforms get priority over ruby regardless of
          # list position, to preserve the "prefer native" invariant.
          # Within non-ruby, earlier in the list wins.
          isRuby = gem.platform == "ruby";
        in
        if isRuby then 10000 + idx else idx;
    in
    builtins.mapAttrs (
      gemName: gemsForName:
      let
        ranked = builtins.sort (a: b: rankGem a < rankGem b) gemsForName;
      in
      builtins.head ranked
    ) gemsByName;
}

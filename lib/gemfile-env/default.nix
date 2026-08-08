# callPackage definitions:
{
  lib,
  stdenv,
  ruby,
  callPackage,
  fetchurl, # replace with buildRubyGem
  buildRubyGem,
  defaultGemConfig,
  buildEnv,

  # debug
  ...
}:

let
  defaultRuby = ruby;
in

# function arguments:
{
  name,
  gemfile,
  gemfileLock,
  platforms ? null, # null = auto-detect from stdenv.hostPlatform.system
  groups ? [
    "default"
    "development"
    "production"
    "test"
  ],
  gemGroups ? null, # null = auto-detect via gem-groups.rb IFD; attrset = override
  gemspec ? null, # path to *.gemspec when the Gemfile uses the `gemspec` directive
  extraFiles ? { }, # { "relative/dest" = ./src; } — files the gemspec require_relatives
  gemConfig ? defaultGemConfig,
  # Credentials for private gem registries, keyed by remote host:
  #   credentials."rubygems.pkg.github.com" = {
  #     usernameVar = "GEM_REGISTRY_USER";
  #     passwordVar = "GEM_REGISTRY_TOKEN";
  #   };
  # The variables are read from the build environment, never from the store.
  # See lib/gemfile-env/credentials.nix for the daemon-environment caveat.
  credentials ? { },
  ruby ? defaultRuby,
  debug ? false, # when true, builtins.trace each gem being built
  ...
}:
let

  # ── parsing ──────────────────────────────────────────────────
  parseGemfileAndLockfile = callPackage ./parse-gemfile-and-lockfile.nix { };
  parsed = parseGemfileAndLockfile {
    inherit
      gemfile
      gemfileLock
      gemGroups
      gemspec
      extraFiles
      ;
  };
  gemMetadata = parsed.gems;
  depGraph = parsed.depGraph;

  # ── credentials (pure logic lives in credentials.nix) ────────
  credentialHelpers = import ./credentials.nix { inherit lib; };
  checkedCredentials = credentialHelpers.warnUnusedCredentials (credentialHelpers.validateCredentials credentials) gemMetadata;

  # ── filtering (pure logic lives in resolve.nix) ─────────────
  filterHelpers = import ./resolve.nix { inherit lib; };
  inherit (filterHelpers)
    filterGroup
    filterPlatform
    resolvePlatforms
    applyGemConfigs
    platformsForSystem
    expandTransitiveDeps
    warnIfNoPlatformGems
    ;

  # Resolve platforms: user-supplied list, or auto-detect from stdenv
  resolvedPlatforms =
    let
      raw = if platforms != null then platforms else platformsForSystem stdenv.hostPlatform.system;
    in
    warnIfNoPlatformGems gemMetadata raw;

  # Step 1: filter by groups
  gemsForGroups = builtins.filter (filterGroup groups) gemMetadata;

  # Step 2: expand transitive deps so build-time dependencies survive
  # (e.g., mini_portile2 needed by ruby-platform nokogiri)
  afterGroupNames = map (g: g.gemName) gemsForGroups;
  expandedNames = expandTransitiveDeps depGraph afterGroupNames;
  expandedGems = builtins.filter (g: builtins.elem g.gemName expandedNames) gemMetadata;

  # Step 3: filter by platform
  gemsForGroupsAndPlatforms = builtins.filter (filterPlatform resolvedPlatforms) expandedGems;

  # Merge user-supplied gemConfig with our local overrides (e.g., nokogiri).
  # The user's config takes precedence: if they supply a nokogiri entry, it
  # replaces ours. To layer on top of ours, they can import and extend it.
  gemConfigs = callPackage ./gem-configs.nix { };

  # Layer: defaultGemConfig < gemConfigs < user gemConfig
  mergedGemConfig = defaultGemConfig // gemConfigs // gemConfig;

  # Resolve platform duplicates FIRST: prefer exact arch match > compatible > ruby.
  # This must happen before applyGemConfigs so that defaultGemConfig entries
  # (which assume source compilation; i.e., Makefiles, build flags, patches) are
  # only applied to ruby-platform gems, not precompiled native variants.
  platformResolvedGemsByName = resolvePlatforms resolvedPlatforms gemsForGroupsAndPlatforms;
  finalGems = lib.attrsets.mapAttrsToList (
    gemName: gemAttrs:
    let
      configured =
        if gemAttrs.platform == "ruby" then applyGemConfigs mergedGemConfig gemAttrs else gemAttrs;
      # buildRubyGem derives `src` from source.remotes and source.sha256 alone,
      # with no way to pass fetchurl the netrc arguments. Handing it a finished
      # `src` is the only opening, so gems on a credentialed remote get one.
      credential = credentialHelpers.credentialFor checkedCredentials configured;
      authenticated =
        if credential == null then
          configured
        else
          configured
          // {
            src = fetchurl (
              {
                urls = credentialHelpers.gemUrls configured;
                inherit (configured.source) sha256;
              }
              // credentialHelpers.netrcFetchAttrs credential
            );
          };
      traced =
        if debug then
          builtins.trace "gems4nix [debug]: building ${configured.gemName} ${configured.version} (${configured.platform})${lib.optionalString (credential != null) " with credentials for ${credential.host}"}" authenticated
        else
          authenticated;
    in
    buildRubyGem traced
  ) platformResolvedGemsByName;
in
buildEnv {
  name = "${name}-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" resolvedPlatforms}";
  paths = finalGems;
  postBuild = ''
    mkdir -p $out/nix-support
    cat > $out/nix-support/setup-hook <<EOF
    export GEM_PATH="$out/${ruby.gemPath}\''${GEM_PATH:+:\$GEM_PATH}"
    EOF
  '';
}

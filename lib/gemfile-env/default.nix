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

  # nokogiri
  zlib,
  libxml2,
  libxslt,
  libiconv,

  # debug
  ...
}:

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
  gemConfig ? defaultGemConfig,
  ruby ? ruby,
  ...
}:
let

  # ── parsing ──────────────────────────────────────────────────
  parseGemfileAndLockfile = callPackage ./parse-gemfile-and-lockfile.nix { };
  gemMetadata = parseGemfileAndLockfile { inherit gemfile gemfileLock; };

  # ── filtering (pure logic lives in filter-helpers.nix) ───────
  filterHelpers = import ./filter-helpers.nix { inherit lib; };
  inherit (filterHelpers) filterGroup filterPlatform resolvePlatforms applyGemConfigs platformsForSystem;

  # Resolve platforms: user-supplied list, or auto-detect from stdenv
  resolvedPlatforms =
    if platforms != null then platforms
    else platformsForSystem stdenv.hostPlatform.system;

  gemsForGroups = builtins.filter (filterGroup groups) gemMetadata;
  gemsForGroupsAndPlatforms = builtins.filter (filterPlatform resolvedPlatforms) gemsForGroups;

  # Merge user-supplied gemConfig with our local overrides (e.g., nokogiri).
  # The user's config takes precedence: if they supply a nokogiri entry, it
  # replaces ours. To layer on top of ours, they can import and extend it.
  nokogiriConfig = {
    nokogiri =
      attrs:
      (
        {
          buildFlags =
            [
              "--use-system-libraries"
              "--with-zlib-lib=${zlib.out}/lib"
              "--with-zlib-include=${zlib.dev}/include"
              "--with-xml2-lib=${libxml2.out}/lib"
              "--with-xml2-include=${libxml2.dev}/include/libxml2"
              "--with-xslt-lib=${libxslt.out}/lib"
              "--with-xslt-include=${libxslt.dev}/include"
              "--with-exslt-lib=${libxslt.out}/lib"
              "--with-exslt-include=${libxslt.dev}/include"
              "--gumbo-dev"
            ]
            ++ lib.optionals stdenv.hostPlatform.isDarwin [
              "--with-iconv-dir=${libiconv}"
              "--with-opt-include=${libiconv}/include"
            ];
        }
        // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
          buildInputs = [ libxml2 ];

          # libxml 2.12 upgrade requires these fixes
          # https://github.com/sparklemotion/nokogiri/pull/3032
          # which don't trivially apply to older versions
          meta.broken =
            (lib.versionOlder attrs.version "1.16.0") && (lib.versionAtLeast libxml2.version "2.12");
        }
      );
  };

  # Layer: defaultGemConfig < nokogiriConfig < user gemConfig
  mergedGemConfig = defaultGemConfig // nokogiriConfig // gemConfig;

  allGems = lib.lists.map (
    gemAttrs:
    buildRubyGem (applyGemConfigs mergedGemConfig gemAttrs)
  ) gemsForGroupsAndPlatforms;

  # resolve platform duplicates: prefer platform-specific over pure ruby
  platformResolvedGemsByName = resolvePlatforms allGems;
  finalGems = lib.attrsets.mapAttrsToList (gemName: gem: gem) platformResolvedGemsByName;
in
buildEnv {
  name = "${name}-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" resolvedPlatforms}";
  paths = finalGems;
}

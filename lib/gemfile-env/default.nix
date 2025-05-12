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
  platforms ? [ "ruby" ],
  groups ? [
    "default"
    "development"
    "production"
    "test"
  ],
  # this isn't coming in the way I expect...
  gemConfig ? defaultGemConfig,
  ...
}:
let

  # TODO update output of parser to better suit buildRubyGem
  parseGemfileAndLockfile = callPackage ./parse-gemfile-and-lockfile.nix { };
  gemMetadata = parseGemfileAndLockfile { inherit gemfile gemfileLock; };

  filterGroup = groups: gem: builtins.length (lib.lists.intersectLists groups gem.groups) > 0;
  filterPlatform = groups: gem: lib.lists.any (p: p == gem.platform) platforms;

  gemsForGroups = builtins.filter (filterGroup groups) gemMetadata;
  gemsForGroupsAndPlatforms = builtins.filter (filterPlatform platforms) gemsForGroups;

  # _foo = builtins.trace defaultGemConfig defaultGemConfig;

  # TODO figure out how to use ruby-modules/bundled-common/functions.nix
  applyGemConfigs =
    attrs: (if gemConfig ? ${attrs.gemName} then attrs // gemConfig.${attrs.gemName} attrs else attrs);

  # customize nokogiri config to add --gumbo-dev build option
  # TODO: fix upstream or make bits of gemConfig more accessible via gemEnv
  gemConfig = defaultGemConfig // {
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

  gems = lib.lists.map (
    gemAttrs:
    let
      attrs = (applyGemConfigs gemAttrs);
    in
    buildRubyGem attrs
  ) gemsForGroupsAndPlatforms;

in
buildEnv {
  name = "gemfile-env-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" platforms}";
  paths = gems;
}

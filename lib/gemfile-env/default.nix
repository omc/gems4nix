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

  # TODO figure out how to use ruby-modules/bundled-common/functions.nix
  applyGemConfigs =
    attrs: (if gemConfig ? ${attrs.gemName} then attrs // gemConfig.${attrs.gemName} attrs else attrs);

  gems = lib.lists.map (gemAttrs: buildRubyGem (applyGemConfigs gemAttrs)) gemsForGroupsAndPlatforms;

in
buildEnv {
  name = "gemfile-env-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" platforms}";
  paths = gems;
}

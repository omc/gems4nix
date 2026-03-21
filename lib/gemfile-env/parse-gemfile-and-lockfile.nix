# TODO: git source
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
}:

let

  helpers = import ./parser-helpers.nix { inherit lib; };
  inherit (helpers) findIndices takeLines parseChecksumLine parseGemSection;

  # use the Gemfile to produce group information for each gem
  gemGroupsJson =
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
        ruby ${./gem-groups.rb} > $out
      '';

  # inputs
  content = builtins.readFile (gemfileLock);
  lines = lib.splitString "\n" content;

  # CHECKSUM section
  checksumSectionIndex = lib.lists.findFirstIndex (line: line == "CHECKSUMS") null lines;
  checksumSectionLines =
    if checksumSectionIndex == null then
      throw "cannot find CHECKSUMS in Gemfile.lock - run 'bundle lock --add-checksums'"
    else
      takeLines checksumSectionIndex lines;
  checksumSection = lib.lists.map (line: parseChecksumLine line) checksumSectionLines;

  # GEM section - may have more than one
  gemSectionIndices = findIndices (l: l == "GEM") lines;
  gemSectionLines = lib.lists.map (i: takeLines i lines) gemSectionIndices;
  gemSections = lib.lists.map parseGemSection gemSectionLines;

  # invert the remote and flatten for all gems for easy lookup
  # { sorbet-static = "https://rubygems.org/"; ... }
  # TODO: group by gem name for multiple remotes; e.g., depot depends on faraday
  # which shows up in both but we prefer rubygems.org. tbd how buildRubyGem handles this.
  gemRemotes = builtins.listToAttrs (
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

  # a map of gem names to urls
  # gemUrls = builtins.listToAttrs (
  #   lib.lists.map (gem: {
  #     name = gem.gemName;
  #     value =
  #       if gem.platform == "ruby" then
  #         "${gemRemotes.${gem.gemName}}gems/${gem.gemName}-${gem.version}.gem"
  #       else
  #         "${gemRemotes.${gem.gemName}}gems/${gem.gemName}-${gem.version}-${gem.platform}.gem";
  #   }) checksumSection
  # );

  # parse the group information that we have generated from the Gemfile
  gemGroups = builtins.fromJSON (builtins.readFile gemGroupsJson);

  # merge the checksummed gems with their urls and groups. NB - caution about
  # grouping these by name: gems may have the same name and version but
  # different platform
  gemsFromGemfileAndLockfile = lib.lists.map (gemAttrs: {
    inherit (gemAttrs)
      gemName
      platform # todo: multiple platforms?
      version
      ;

    # todo: with nokogiri, mini_portile2 shows up in the lock but didn't make
    # its way into my gem groups parser. that's okay because it's a build-time
    # dependency that we don't actually need. but still. what's the proper
    # fallback in a case like this? when can these happen?
    groups = gemGroups.${gemAttrs.gemName} or [ ];

    source = gemAttrs.source // {
      remotes = [ gemRemotes.${gemAttrs.gemName} ]; # todo multiple remotes?
      type = "gem"; # todo different types; git; source
    };
  }) checksumSection;

in
gemsFromGemfileAndLockfile

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

  # parse a gem checksum line
  # "  zeitwerk (2.6.18) sha256=bd2d213996ff7b3b364cd342a585fbee9797dbc1c0c6d868dc4150cc75739781"
  parseChecksumLine =
    line:
    let
      parts = lib.splitString " " (lib.strings.removePrefix "  " line);
      gemName = builtins.elemAt parts 0;
      versionParts = lib.splitString "-" (
        lib.strings.removeSuffix ")" (lib.strings.removePrefix "(" (builtins.elemAt parts 1))
      );
      version = builtins.elemAt versionParts 0;
      platform =
        if builtins.length versionParts > 1 then
          (lib.strings.concatStringsSep "-" (lib.lists.drop 1 versionParts))
        else
          "ruby";
      hashParts = lib.splitString "=" (builtins.elemAt parts 2);
      sha256 = builtins.elemAt hashParts 1;
    in
    {
      inherit
        version
        platform
        gemName
        ;
      source = { inherit sha256; };
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
  checksumSectionLines = takeLines checksumSectionIndex lines;
  checksumSection = lib.lists.map (line: parseChecksumLine line) checksumSectionLines;

  # GEM section - may have more than one
  gemSectionIndices = findIndices (l: l == "GEM") lines;
  gemSectionLines = lib.lists.map (i: takeLines i lines) gemSectionIndices;
  gemSections = lib.lists.map parseGemSection gemSectionLines;

  # invert the remote and flatten for all gems for easy lookup
  # { sorbet-static = "https://rubygems.org/"; ... }
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

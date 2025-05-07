# callPackage definitions:
{ lib, ... }:

# function arguments:
{
  gemfileLock,
  platforms ? [ "ruby" ],
  ...
}:
let

  ## helper functions

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
      name = builtins.elemAt parts 0;
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
      hash = builtins.elemAt hashParts 1;
    in
    {
      inherit
        name
        version
        platform
        hash
        ;
    };

  # given a bunch of lines that represent a GEM section, return the remote and the list of gems.
  # we're not concerned with the version specs here, since we'll get that later from the checksum.
  # this is just to reconstruct a url to the gem file later.
  parseGemSection =
    lines:
    let
      remote = builtins.elemAt (lib.strings.splitString ": " (builtins.elemAt lines 0)) 1;
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

  # merge the checksummed gems with a url constructed from their remotes
  # [ { hash = "830f2eb10..."; name = "sorbet-static"; platform = "universal-darwin"; url = "https://rubygems.org/gems/sorbet-static-0.5.12070.gem"; version = "0.5.12070"; } ... ]
  gems = lib.lists.map (
    gem:
    {
      url =
        let
          remote = gemRemotes.${gem.name};
        in
        "${remote}gems/${gem.name}-${gem.version}.gem";
    }
    // gem
  ) checksumSection;

  # group by platform, since that will be the main point of interface when
  # constructing packages and devshells
  gemsByPlatform = lib.lists.groupBy (gem: gem.platform) gems;

in
gemsByPlatform

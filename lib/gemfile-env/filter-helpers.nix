# Pure helper functions for filtering and resolving gems.
# No nixpkgs build dependencies, only lib.
{ lib }:

{
  # Keep gems whose groups overlap with the requested groups.
  # Returns true if the gem should be included.
  filterGroup = groups: gem:
    builtins.length (lib.lists.intersectLists groups gem.groups) > 0;

  # Keep gems whose platform matches one of the requested platforms.
  # Returns true if the gem should be included.
  filterPlatform = platforms: gem:
    lib.lists.any (p: p == gem.platform) platforms;

  # Given a list of gems (possibly containing duplicates for different
  # platforms), resolve to one gem per name. Prefer platform-specific gems
  # over pure-ruby ones.
  #
  # Returns: attrset of gemName -> single gem
  resolvePlatforms = gems:
    let
      gemsByName = builtins.groupBy (g: g.gemName) gems;
    in
    builtins.mapAttrs (
      gemName: gemsForName:
      let
        otherPlatformGems = builtins.filter (g: g.platform != "ruby") gemsForName;
        rubyPlatformGems = builtins.filter (g: g.platform == "ruby") gemsForName;
      in
      # TODO: noisy warning if we have more than one in either branch here
      if otherPlatformGems != [ ] then
        builtins.elemAt otherPlatformGems 0
      else
        builtins.elemAt rubyPlatformGems 0
    ) gemsByName;
}

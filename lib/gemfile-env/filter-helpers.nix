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

  # Apply per-gem configuration overrides from gemConfig.
  # gemConfig is an attrset of { gemName = attrs: { ... }; ... }.
  # If gemConfig has an entry for this gem, call it with the gem's attrs and
  # merge the result. Otherwise return attrs unchanged.
  applyGemConfigs = gemConfig: attrs:
    if gemConfig ? ${attrs.gemName} then
      attrs // gemConfig.${attrs.gemName} attrs
    else
      attrs;

  # Map a nixpkgs system string to the Ruby platform strings that should be
  # accepted from a Gemfile.lock. Always includes "ruby" (pure-Ruby gems).
  #
  # The mapping covers the four systems that RubyGems publishes pre-built
  # native gems for. Musl variants are included for Alpine/NixOS-static.
  # Unknown systems throw with a clear message so users know to override.
  platformsForSystem = system:
    let
      mapping = {
        "aarch64-darwin" = [ "ruby" "arm64-darwin" "universal-darwin" ];
        "x86_64-darwin"  = [ "ruby" "x86_64-darwin" "universal-darwin" ];
        "aarch64-linux"  = [ "ruby" "aarch64-linux" "aarch64-linux-gnu" "aarch64-linux-musl" ];
        "x86_64-linux"   = [ "ruby" "x86_64-linux" "x86_64-linux-gnu" "x86_64-linux-musl" ];
      };
    in
    if mapping ? ${system} then
      mapping.${system}
    else
      throw "platformsForSystem: unsupported system '${system}'. Pass an explicit `platforms` list or extend platformsForSystem.";

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

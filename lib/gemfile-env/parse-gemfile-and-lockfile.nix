# TODO: git source
#
# IO shell: reads files, runs Ruby for group info, delegates pure logic to
# parser-helpers.nix. All testable logic lives there.
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
  inherit (helpers) parseLockfileContent buildGemRemotes mergeGemMetadata;

  # ── IO ───────────────────────────────────────────────────────

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

  # ── pure assembly (delegated to helpers) ─────────────────────

  content = builtins.readFile gemfileLock;
  parsed = parseLockfileContent content;
  gemRemotes = buildGemRemotes parsed.gemSections;
  gemGroups = builtins.fromJSON (builtins.readFile gemGroupsJson);

in
mergeGemMetadata {
  inherit (parsed) checksumSection;
  inherit gemRemotes gemGroups;
}

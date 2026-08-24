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
  # Base directory that PATH `remote:` values are resolved against. Bundler
  # writes them relative to the Gemfile's directory, which is the default.
  root ? null,
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

  pathRoot = if root != null then root else builtins.dirOf gemfile;

  # Resolve PATH remotes eagerly so a missing directory names the `root`
  # argument here, rather than surfacing as an opaque unpack failure inside
  # buildRubyGem much later.
  pathSections = lib.lists.map (
    section:
    let
      resolved = pathRoot + "/${section.remote}";
    in
    if builtins.pathExists resolved then
      section
    else
      throw "gems4nix: PATH source '${section.remote}' does not exist at ${toString resolved}. Pass `root` to gemfileEnv if the Gemfile is not co-located with its path gems."
  ) parsed.pathSections;

in
mergeGemMetadata {
  inherit (parsed) checksumSection gitSections;
  inherit
    gemRemotes
    gemGroups
    pathSections
    pathRoot
    ;
}

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
  gitMinimal,

  # nokogiri
  zlib,
  libxml2,
  libxslt,
  libiconv,

  # debug
  ...
}@defs:

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
  # Write `defs.ruby`, not `ruby`. An argument's default can see the argument
  # itself, so `ruby ? ruby` describes itself and never finishes.
  ruby ? defs.ruby,
  # Directory that PATH sources are relative to. Defaults to the directory
  # holding the Gemfile, which is what Bundler writes them relative to.
  root ? null,
  # Replace the source of one git gem. Give a derivation or path to use as
  # `src`, or a function that receives the gem's `source` and returns one.
  #
  # Use this to avoid builtins.fetchGit. That function runs while Nix
  # evaluates, needs the network then, and no binary cache can serve its
  # result. A fetchgit with a known hash has none of those limits.
  gemSrcOverrides ? { },
  ...
}:
let

  # ── parsing ──────────────────────────────────────────────────
  parseGemfileAndLockfile = callPackage ./parse-gemfile-and-lockfile.nix { };
  gemMetadata = parseGemfileAndLockfile { inherit gemfile gemfileLock root; };

  # ── filtering (pure logic lives in filter-helpers.nix) ───────
  filterHelpers = import ./filter-helpers.nix { inherit lib; };
  inherit (filterHelpers)
    filterGroup
    filterPlatform
    resolvePlatforms
    applyGemConfigs
    platformsForSystem
    ;

  # Resolve platforms: user-supplied list, or auto-detect from stdenv
  resolvedPlatforms =
    if platforms != null then platforms else platformsForSystem stdenv.hostPlatform.system;

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
          buildFlags = [
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

  # Resolve platform duplicates FIRST: prefer exact arch match > compatible > ruby.
  # This must happen before applyGemConfigs so that defaultGemConfig entries
  # (which assume source compilation; i.e., Makefiles, build flags, patches) are
  # only applied to ruby-platform gems, not precompiled native variants.
  platformResolvedGemsByName = resolvePlatforms resolvedPlatforms gemsForGroupsAndPlatforms;

  # ── git and path sources ─────────────────────────────────────
  #
  # We build git and path gems as `type = "gem"` with our own `src`. We do not
  # use buildRubyGem's `type = "git"`. Three reasons:
  #
  #   1. `type = "git"` installs the gem into bundler/gems/ and writes no
  #      specifications/*.gemspec. RubyGems finds gems through GEM_PATH, and it
  #      needs that file. So `require` fails.
  #   2. A setup-hook can find such a gem instead. But buildEnv deletes the
  #      nix-support directory, and the hook lives there.
  #   3. `type = "git"` also needs a sha256. A Gemfile.lock has no such field.
  #
  # Path gems must not use the pathDerivation helper either. TODO item 13
  # explains both rejections and what would have to change first.
  #
  # When we pass `src`, buildRubyGem skips its own fetcher. A directory `src`
  # then unpacks the normal stdenv way, and the gem builds and installs.
  mkGemSrc =
    gem:
    if gem.source.type == "git" then
      builtins.fetchGit (
        {
          inherit (gem.source) url rev;
          # A locked revision is often not the tip of a branch. Some git
          # servers refuse to send such a revision on its own, because
          # `uploadpack.allowAnySHA1InWant` is off by default. Fetch every ref
          # to get it. The revision alone decides the result, so this costs
          # only fetch time.
          allRefs = true;
        }
        // lib.optionalAttrs gem.source.fetchSubmodules { submodules = true; }
      )
    else
      gem.source.path;

  # An override for a gem with no git or path source does nothing. If we ignore
  # it, a user who misspells a gem name still gets the network fetch they were
  # trying to avoid. So we refuse instead.
  #
  # We compare against every git and path gem in the lockfile, not against the
  # gems left after we filter by group and platform. An override for a
  # test-group gem in a production build is then still valid.
  sourcedGemNames = builtins.map (g: g.gemName) (
    builtins.filter (g: g.source.type != "gem") gemMetadata
  );
  unknownSrcOverrides = builtins.filter (n: !(builtins.elem n sourcedGemNames)) (
    builtins.attrNames gemSrcOverrides
  );
  srcOverridesChecked =
    if unknownSrcOverrides != [ ] then
      throw "gems4nix: gemSrcOverrides names '${builtins.head unknownSrcOverrides}', which has no GIT or PATH source in the lockfile"
    else
      true;

  # buildRubyGem uses its own ruby unless we give it one. Without this, the
  # `ruby` argument above would be accepted and then ignored. A per-gem `ruby`
  # from gemConfig still wins.
  buildGem =
    attrs:
    if attrs.source.type == "gem" then
      buildRubyGem (attrs // { ruby = attrs.ruby or ruby; })
    else
      buildRubyGem (
        attrs
        // {
          ruby = attrs.ruby or ruby;
          type = "gem";
          src =
            if gemSrcOverrides ? ${attrs.gemName} then
              let
                override = gemSrcOverrides.${attrs.gemName};
              in
              if builtins.isFunction override then override attrs.source else override
            else
              mkGemSrc attrs;
          # applyGemConfigs runs before this, so add to what the user set
          # instead of replacing it.
          nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ gitMinimal ];
          # Many gemspecs list their files with `git ls-files`. Neither a
          # fetchGit result nor a copied path source has a .git directory, so
          # that command returns nothing. The gem then builds without error and
          # contains no files at all. Make a throwaway repository to prevent
          # this.
          preBuild = ''
            ${attrs.preBuild or ""}
            if [ ! -d .git ]; then
              git init -q
              git add -A
            fi
          '';
          # An empty gem gives no error until someone calls `require`. Check
          # here instead. buildRubyGem sets $GEM_HOME before this runs.
          postInstall = ''
            ${attrs.postInstall or ""}
            gems4nixSpec="$GEM_HOME/specifications/${attrs.gemName}-${attrs.version}.gemspec"
            gems4nixDir="$GEM_HOME/gems/${attrs.gemName}-${attrs.version}"
            if [ ! -f "$gems4nixSpec" ]; then
              echo "gems4nix: ${attrs.gemName} installed no gemspec at $gems4nixSpec" >&2
              exit 1
            fi
            if [ -z "$(ls -A "$gems4nixDir" 2>/dev/null)" ]; then
              echo "gems4nix: ${attrs.gemName} installed an empty $gems4nixDir;" >&2
              echo "  its gemspec probably computed an empty spec.files (git ls-files)." >&2
              exit 1
            fi
          '';
        }
      );

  finalGems = lib.attrsets.mapAttrsToList (
    gemName: gemAttrs:
    let
      configured =
        if gemAttrs.platform == "ruby" then applyGemConfigs mergedGemConfig gemAttrs else gemAttrs;
    in
    buildGem configured
  ) platformResolvedGemsByName;
in
assert srcOverridesChecked == true;
buildEnv {
  name = "${name}-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" resolvedPlatforms}";
  paths = finalGems;
}

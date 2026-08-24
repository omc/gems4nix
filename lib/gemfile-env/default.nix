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
  # `ruby ? ruby` would be self-referential: a formal's default is evaluated in
  # a scope that already binds that formal, so forcing it recurses forever.
  ruby ? defs.ruby,
  # Base directory for PATH sources in the lockfile. Defaults to the Gemfile's
  # own directory, which is what Bundler writes those remotes relative to.
  root ? null,
  # Per-gem escape hatch for git sources: either a derivation/path used
  # verbatim as `src`, or a function taking the gem's `source` attrset.
  # Lets an offline or hermetic build swap builtins.fetchGit (which fetches at
  # eval time and is not substitutable) for a fixed-output fetchgit.
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
  # These are built as `type = "gem"` with an explicit `src`, NOT with
  # buildRubyGem's `type = "git"` / bundled-common's `pathDerivation`. Both of
  # those are structurally incompatible with a plain buildEnv:
  #
  #   - `type = "git"` installs via nix-bundle-install.rb, which puts the gem
  #     under bundler/gems/<name>-<rev> with no specifications/*.gemspec, so
  #     RubyGems cannot see it through GEM_PATH. Only the nix-support
  #     setup-hook or Bundler.setup reaches it -- and buildEnv drops
  #     nix-support outright (build-support/buildenv/builder.pl). Switching to
  #     it requires binstubs (TODO #10) first.
  #   - `type = "git"` also demands source.sha256, which a Gemfile.lock does
  #     not contain.
  #   - `pathDerivation` is a fake derivation whose outPath is the raw source
  #     dir; its lib/ would land at $out/lib, not on GEM_PATH.
  #
  # buildRubyGem's `src` is `attrs.src or (...)`, so supplying it bypasses the
  # fetcher and never forces attrs.source. With a directory src, unpackPhase
  # falls through to stdenv's and re-enables buildPhase, giving us the standard
  # `gem build` + `gem install` layout. See TODO #13.
  mkGemSrc =
    gem:
    if gem.source.type == "git" then
      builtins.fetchGit (
        {
          inherit (gem.source) url rev;
          # A locked revision is frequently not a branch tip, and not every git
          # server enables uploadpack.allowAnySHA1InWant. Costs a full-refs
          # fetch; the output path is determined by rev either way.
          allRefs = true;
        }
        // lib.optionalAttrs gem.source.fetchSubmodules { submodules = true; }
      )
    else
      gem.source.path;

  buildGem =
    attrs:
    if attrs.source.type == "gem" then
      buildRubyGem attrs
    else
      buildRubyGem (
        attrs
        // {
          type = "gem";
          src =
            if gemSrcOverrides ? ${attrs.gemName} then
              let
                override = gemSrcOverrides.${attrs.gemName};
              in
              if builtins.isFunction override then override attrs.source else override
            else
              mkGemSrc attrs;
          # applyGemConfigs has already run, so compose rather than clobber:
          # a user gemConfig entry's preBuild is kept and ours appended.
          nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ gitMinimal ];
          # Load-bearing, not decorative: gemspecs commonly compute spec.files
          # via `git ls-files`, and neither builtins.fetchGit output nor a store
          # copy of a path source has a .git. Without an index the gem builds
          # successfully and ships zero files.
          preBuild = ''
            ${attrs.preBuild or ""}
            if [ ! -d .git ]; then
              git init -q
              git add -A
            fi
          '';
          # ...and because that failure mode is silent, assert the gem actually
          # installed something RubyGems can find.
          # $GEM_HOME is exported by buildRubyGem's own installPhase, so this
          # tracks whichever ruby actually did the install.
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
buildEnv {
  name = "${name}-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" resolvedPlatforms}";
  paths = finalGems;
}

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

  # debug
  ...
}:

let
  defaultRuby = ruby;
  argHelpers = import ./arguments.nix { inherit lib; };
  bundlerHelpers = import ./bundler.nix { inherit lib; };
  parseHelpers = import ./parse.nix { inherit lib; };

  # function arguments:
  gemfileEnv =
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
      gemGroups ? null, # null = auto-detect via gem-groups.rb IFD; attrset = override
      gemspec ? null, # path to *.gemspec when the Gemfile uses the `gemspec` directive
      extraFiles ? { }, # { "relative/dest" = ./src; } — files the gemspec require_relatives
      # Directory that PATH sources resolve against. Defaults to the directory
      # holding the Gemfile, which is what Bundler writes them relative to.
      root ? null,
      # Replace the source of one git or path gem, keyed by gem name. Give a
      # derivation or path to use as `src`, or a function that receives the
      # gem's `source` and returns one.
      #
      # This is the way around builtins.fetchGit, which runs while Nix
      # evaluates, needs the network and any credentials then, and produces a
      # path no binary cache can serve. A fetchgit with a known hash has none
      # of those limits.
      gemSrcOverrides ? { },
      gemConfig ? defaultGemConfig,
      # Credentials for private gem registries, keyed by remote host:
      #   credentials."rubygems.pkg.github.com" = {
      #     usernameVar = "GEM_REGISTRY_USER";
      #     passwordVar = "GEM_REGISTRY_TOKEN";
      #   };
      # The variables are read from the build environment, never from the store.
      # See lib/gemfile-env/credentials.nix for the daemon-environment caveat.
      credentials ? { },
      ruby ? defaultRuby,
      debug ? false, # when true, builtins.trace each gem being built
      # `...` collects the arguments checkArgs rejects below, so the error names
      # them instead of Nix aborting uncatchably on the first one.
      ...
    }@args:
    let

      # ── parsing ──────────────────────────────────────────────────
      parseGemfileAndLockfile = callPackage ./parse-gemfile-and-lockfile.nix { };
      parsed = parseGemfileAndLockfile {
        inherit
          gemfile
          gemfileLock
          gemGroups
          gemspec
          extraFiles
          root
          ;
      };
      gemMetadata = parsed.gems;
      depGraph = parsed.depGraph;

      # ── the Ruby the lockfile was resolved with ──────────────────
      #
      # A lockfile that names one and disagrees with `ruby` describes an
      # environment other than the one being built. Across the ABI that is
      # every gem, so it throws; below it, it is a warning, because the
      # requirement Bundler enforces is the Gemfile's and this value only
      # records what resolution happened to run on.
      rubyVerdict = parseHelpers.rubyVersionVerdict {
        locked = parsed.rubyVersion;
        actual = ruby.version;
      };
      applyRubyVerdict =
        value:
        if rubyVerdict == null then
          value
        else if rubyVerdict.level == "error" then
          throw rubyVerdict.message
        else
          lib.warn rubyVerdict.message value;

      # ── credentials (pure logic lives in credentials.nix) ────────
      credentialHelpers = import ./credentials.nix { inherit lib; };
      checkedCredentials = credentialHelpers.warnUnusedCredentials (credentialHelpers.validateCredentials credentials) gemMetadata;

      # ── filtering (pure logic lives in resolve.nix) ─────────────
      filterHelpers = import ./resolve.nix { inherit lib; };
      inherit (filterHelpers)
        filterGroup
        filterPlatform
        resolvePlatforms
        applyGemConfigs
        platformsForSystem
        expandTransitiveDeps
        warnIfNoPlatformGems
        ;

      # Resolve platforms: user-supplied list, or auto-detect from stdenv
      resolvedPlatforms =
        let
          raw = if platforms != null then platforms else platformsForSystem stdenv.hostPlatform.system;
        in
        warnIfNoPlatformGems gemMetadata raw;

      # Step 1: filter by groups
      gemsForGroups = builtins.filter (filterGroup groups) gemMetadata;

      # Step 2: expand transitive deps so build-time dependencies survive
      # (e.g., mini_portile2 needed by ruby-platform nokogiri)
      afterGroupNames = map (g: g.gemName) gemsForGroups;
      expandedNames = expandTransitiveDeps depGraph afterGroupNames;
      expandedGems = builtins.filter (g: builtins.elem g.gemName expandedNames) gemMetadata;

      # Step 3: filter by platform
      gemsForGroupsAndPlatforms = builtins.filter (filterPlatform resolvedPlatforms) expandedGems;

      # Merge user-supplied gemConfig with our local overrides (e.g., nokogiri).
      # The user's config takes precedence: if they supply a nokogiri entry, it
      # replaces ours. To layer on top of ours, they can import and extend it.
      gemConfigs = callPackage ./gem-configs.nix { };

      # Layer: defaultGemConfig < gemConfigs < user gemConfig
      mergedGemConfig = defaultGemConfig // gemConfigs // gemConfig;

      # ── git and path sources ─────────────────────────────────────
      #
      # A git or path gem builds as an ordinary gem with a `src` we supply,
      # never as buildRubyGem's own `type = "git"`. That type installs into
      # bundler/gems/ and writes no specifications/*.gemspec, which is the file
      # RubyGems needs to find a gem on GEM_PATH, so `require` fails. A
      # setup-hook could point at it instead, but buildEnv drops the
      # nix-support directory a hook lives in. And it wants a sha256, which a
      # Gemfile.lock does not record for these sources. The pathDerivation
      # helper is out for the same gemspec-less reason.
      #
      # Given a `src`, buildRubyGem skips its own fetcher, and a directory
      # unpacks the ordinary stdenv way.
      mkGemSrc =
        gem:
        if gem.source.type == "git" then
          builtins.fetchGit (
            {
              inherit (gem.source) url rev;
              # A locked revision is often not the tip of a branch, and a git
              # server refuses to send such a revision on its own unless
              # `uploadpack.allowAnySHA1InWant` is on, which it is not by
              # default. Fetching every ref gets it. The revision alone decides
              # the result, so this costs only fetch time.
              allRefs = true;
            }
            // lib.optionalAttrs gem.source.fetchSubmodules { submodules = true; }
          )
        else
          gem.source.path;

      # An override for a gem with no git or path source does nothing. Ignoring
      # it leaves a user who misspelled a gem name with the network fetch they
      # were trying to avoid, so refuse instead.
      #
      # The comparison is against every git and path gem in the lockfile, not
      # against the gems left after group and platform filtering, so an
      # override for a test-group gem stays valid in a production build.
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

      # Every gem goes through here so it is built against the caller's `ruby`.
      # buildRubyGem defaults to nixpkgs' own, and left to it an overridden
      # `ruby` would move GEM_PATH without moving the gems it points at. A
      # per-gem `ruby` from gemConfig still wins. A git or path gem takes the
      # longer branch and gains the `src` and phases described above.
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
              # rather than replacing it.
              nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ gitMinimal ];
              # Many gemspecs list their files with `git ls-files`. Neither a
              # fetchGit result nor a copied path source has a .git directory,
              # so that command returns nothing, and the gem then builds with
              # no error and no files. A throwaway repository prevents this.
              preBuild = ''
                ${attrs.preBuild or ""}
                if [ ! -d .git ]; then
                  git init -q
                  git add -A
                fi
              '';
              # An empty gem gives no error until someone calls `require`.
              # Check here instead.
              #
              # This runs before any caller-supplied postInstall, not after.
              # runHook evals a hook in the builder's own shell, so an `exit`
              # anywhere in a gemConfig entry ends the build then and there,
              # reporting success. Anything appended after it never runs, and
              # neither does a later phase. Going first is what makes the check
              # unskippable.
              #
              # $out rather than $GEM_HOME: buildRubyGem exports that variable
              # inside installPhase, and this text is not tied to that phase.
              postInstall =
                let
                  gemRoot = "$out/${ruby.gemPath}";
                  # Bundler resolves a GIT-sourced gem only out of
                  # bundler/gems/<scope>, so the RubyGems layout above leaves
                  # it invisible to `require "bundler/setup"`. Give Bundler a
                  # second view of the same gem rather than moving it: plain
                  # `require` still has to work for a consumer that never
                  # boots through Bundler.
                  #
                  # The entries are symlinked, and the serialized gemspec from
                  # specifications/ is used in place of whatever the source
                  # tree ships. That file evaluates anywhere, while a source
                  # gemspec often shells out to `git ls-files` or reads a
                  # sibling it no longer sits beside. Exactly one gemspec ends
                  # up here, because Bundler loads every one it globs.
                  #
                  # This runs before any caller-supplied postInstall for the
                  # same reason the empty-gem check does: an `exit` there must
                  # not be able to leave a git gem Bundler cannot see.
                  bundlerLayout = lib.optionalString (attrs.source.type == "git") ''
                    gems4nixScope="${gemRoot}/bundler/gems/${bundlerHelpers.gitScope attrs.source}"
                    mkdir -p "$gems4nixScope"
                    for gems4nixEntry in "$gems4nixDir"/*; do
                      case "$gems4nixEntry" in *.gemspec) continue ;; esac
                      ln -s "../../../gems/${attrs.gemName}-${attrs.version}/$(basename "$gems4nixEntry")" "$gems4nixScope/"
                    done
                    cp "$gems4nixSpec" "$gems4nixScope/${attrs.gemName}.gemspec"
                  '';
                in
                ''
                  gems4nixSpec="${gemRoot}/specifications/${attrs.gemName}-${attrs.version}.gemspec"
                  gems4nixDir="${gemRoot}/gems/${attrs.gemName}-${attrs.version}"
                  if [ ! -f "$gems4nixSpec" ]; then
                    echo "gems4nix: ${attrs.gemName} installed no gemspec at $gems4nixSpec" >&2
                    exit 1
                  fi
                  if [ -z "$(ls -A "$gems4nixDir" 2>/dev/null)" ]; then
                    echo "gems4nix: ${attrs.gemName} installed an empty $gems4nixDir;" >&2
                    echo "  its gemspec probably computed an empty spec.files (git ls-files)." >&2
                    exit 1
                  fi
                  ${bundlerLayout}
                  ${attrs.postInstall or ""}
                '';
            }
          );

      # Resolve platform duplicates FIRST: prefer exact arch match > compatible > ruby.
      # This must happen before applyGemConfigs so that defaultGemConfig entries
      # (which assume source compilation; i.e., Makefiles, build flags, patches) are
      # only applied to ruby-platform gems, not precompiled native variants.
      platformResolvedGemsByName = resolvePlatforms resolvedPlatforms gemsForGroupsAndPlatforms;
      finalGems = lib.attrsets.mapAttrsToList (
        gemName: gemAttrs:
        let
          configured =
            if gemAttrs.platform == "ruby" then applyGemConfigs mergedGemConfig gemAttrs else gemAttrs;
          # buildRubyGem derives `src` from source.remotes and source.sha256 alone,
          # with no way to pass fetchurl the netrc arguments. Handing it a finished
          # `src` is the only opening, so gems on a credentialed remote get one.
          gemCredentials = credentialHelpers.credentialsFor checkedCredentials configured;
          authenticated =
            if gemCredentials == [ ] then
              configured
            else
              configured
              // {
                src = fetchurl (
                  {
                    urls = credentialHelpers.gemUrls configured;
                    inherit (configured.source) sha256;
                  }
                  // credentialHelpers.netrcFetchAttrs gemCredentials
                );
              };
          traced =
            if debug then
              builtins.trace "gems4nix [debug]: building ${configured.gemName} ${configured.version} (${configured.platform})${lib.optionalString (gemCredentials != [ ]) " with credentials for ${lib.concatMapStringsSep ", " (c: c.host) gemCredentials}"}" authenticated
            else
              authenticated;
        in
        buildGem traced
      ) platformResolvedGemsByName;
    in
    argHelpers.checkArgs "gemfileEnv" gemfileEnv args (
      applyRubyVerdict (
        assert srcOverridesChecked == true;
        buildEnv {
          name = "${name}-${lib.strings.concatStringsSep "-" groups}-${lib.strings.concatStringsSep "-" resolvedPlatforms}";
          paths = finalGems;
          # GEM_HOME is what decides where Bundler looks for a git gem: its
          # install path is Gem.dir, and BUNDLE_PATH is not a substitute because
          # Bundler appends ruby/<version> to that one. Setting it unconditionally
          # rather than only when unset, because an inherited GEM_HOME is exactly
          # the case where a git gem goes missing and nothing says why. The
          # environment is read-only, so `gem install` into it fails; declare the
          # gem in the Gemfile instead.
          #
          # GEM_PATH accumulates and GEM_HOME cannot, so two of these
          # environments in one shell would leave the loser's git gems out of
          # Bundler's reach while plain `require` still found them. That is the
          # failure this whole layout exists to remove, one level up, so the
          # second one refuses instead. GEMS4NIX_GEM_HOME is what distinguishes
          # another gems4nix environment from a GEM_HOME the user brought, which
          # is overridden without comment. It has to name a directory that is
          # really there, because refusing costs a shell and a stray export
          # should not be able to do that.
          #
          # Both variables describe a build environment. Nothing here bakes
          # either into an output, and a build recipe that captures one is
          # recording the machine it ran on.
          postBuild =
            let
              gemHome = "$out/${ruby.gemPath}";
            in
            ''
              mkdir -p $out/nix-support
              cat > $out/nix-support/setup-hook <<EOF
              gems4nixGemHome="${gemHome}"
              EOF
              cat >> $out/nix-support/setup-hook <<'HOOK'
              gems4nixOther="''${GEMS4NIX_GEM_HOME-}"
              case "''$gems4nixOther" in
                /nix/store/*) [ -d "''$gems4nixOther" ] || gems4nixOther="" ;;
                *) gems4nixOther="" ;;
              esac
              if [ -n "''$gems4nixOther" ] && [ "''$gems4nixOther" != "''$gems4nixGemHome" ]; then
                echo 'gems4nix: two gems4nix environments are on this shell, and GEM_HOME can only name one.' >&2
                echo "  already here: ''$gems4nixOther" >&2
                echo "  and now:      ''$gems4nixGemHome" >&2
                echo 'Bundler reads a git gem only from bundler/gems under GEM_HOME, so the git gems of' >&2
                echo 'whichever environment loses go missing from require "bundler/setup" while a plain' >&2
                echo 'require still finds them. Build one gemfileEnv from both Gemfiles, or keep the two' >&2
                echo 'environments in separate shells.' >&2
                exit 1
              fi
              export GEMS4NIX_GEM_HOME="''$gems4nixGemHome"
              export GEM_HOME="''$gems4nixGemHome"
              export GEM_PATH="''$gems4nixGemHome''${GEM_PATH:+:''$GEM_PATH}"
              unset gems4nixGemHome gems4nixOther
              HOOK
            '';
        }
      )
    );
in
gemfileEnv

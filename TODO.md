# TODO

## Critiques and Recommendations

### Parser (`parse-gemfile-and-lockfile.nix`)

1. **Version-platform splitting on `-` is naive.**
   `lib.splitString "-"` on the version token breaks for multi-segment semver
   pre-release versions (e.g., `1.0.0-beta.1`). A gem version like
   `1.0.0-beta1-arm64-darwin` would be misparsed: `version = "1.0.0"`,
   `platform = "beta1-arm64-darwin"`. In practice Ruby gems don't use
   pre-release hyphens in the lockfile (they use `.pre.`), but the parser
   doesn't assert this; it silently miscategorizes.

2. **`takeLines` processes the entire remaining file after `start`.**
   `builtins.foldl'` iterates over every line after the start index, even
   though it stops collecting at the first blank line. For a 1000-line lockfile
   with the CHECKSUMS section at line 745, `takeLines` for the first GEM
   section iterates ~1000 lines. This isn't a correctness bug but is worth
   noting for very large lockfiles.

3. **`gemRemotes` first-writer-wins for duplicate gem names.**
   `builtins.listToAttrs` on a flattened list means if the same gem name
   appears in multiple GEM sections (e.g., `faraday` from both rubygems.org
   and a private registry), only the first section's remote survives. The TODO
   in `parser-helpers.nix` acknowledges this, but the current behavior is
   silently arbitrary rather than loudly wrong.

   `parseGemSection` also reads only `lines[0]` for the remote and treats
   everything from index 2 as a gem name, so a section with two `remote:`
   lines misparses. `parseSectionBody` (added for GIT/PATH) already handles
   repeated keys and indent depth correctly and would make this fix cheap.

4. ~~**No support for git or path sources.**~~ **Done** (see #13 for how, and
   for what is still missing). GIT and PATH sections are parsed and built.
   A hashless `CHECKSUMS` line that no GIT/PATH section explains is now an
   evaluation error rather than a silent drop.

### Filtering and Building (`default.nix`)

5. **Empty group gems fall through filtering (confirmed regression).**
   Gems with `groups = []` (like `mini_portile2`, a build-time dependency)
   are filtered out by `filterGroup` since their intersection with any
   requested groups is empty. This causes a real build failure when a
   lockfile contains only the `ruby` platform variant of nokogiri (no
   precompiled platform gems like `arm64-darwin`): the ruby variant requires
   `mini_portile2` to compile, but it's been dropped.

   Error: `Could not find 'mini_portile2' (~> 2.8.2)` during nokogiri build.

   **Pinned in:** `test/unit/test-filter.nix` →
   `test_ruby_only_nokogiri_drops_build_deps`, which asserts the *wrong*
   current behaviour so the suite can gate CI. Invert it and rename it back to
   `..._keeps_build_deps` when this is fixed.

   **Pending test:** `test/unit/test-pending.nix` →
   `test_transitive_git_gem_survives_group_filter` asserts the behaviour we
   want and fails today. It covers the git-gem form of this bug: a git gem
   reached only through another gem's dependency list gets no groups and
   disappears.

   `test_filterGroup_git_gem_without_groups` pins the same bug for a
   git-sourced gem: a transitively-reached git gem that `gem-groups.rb` misses
   would still vanish silently. Top-level git/path gems get `["default"]`, so
   this does not bite the examples today.

   **Fix options:**
   - Parse the dependency graph from the lockfile `specs:` section (see #12,
     #14) and include transitive deps of resolved gems regardless of group.
   - Have `gem-groups.rb` propagate groups to build-time deps like
     `mini_portile2`.
   - Add a post-resolution step that pulls in dependencies of ruby-variant
     gems using `composeGemAttrs` / `gemPath` (see #9).

### General

6. ~~**No CI or automated test invocation.**~~ **Done.**
   `.github/workflows/ci.yml` runs the root `nix flake check`, both unit test
   files, and a matrix over the three examples. Not a single top-level
   `nix flake check`: the unit tests use an unpinned `fetchTarball` (illegal
   under pure flake eval) and the examples take `path:../..` as an input,
   which would be a cycle. See TESTING.md.

7. **`gem-groups.rb` group propagation may over-propagate.**
   The Ruby script iterates all specs and propagates groups through
   descendants, but it does this for every spec regardless of whether that
   spec is a top-level dependency. A transitive dep shared by gems in
   different groups accumulates all groups, which may cause it to appear in
   groups the user didn't request (though this is arguably correct).

### Upstream nixpkgs alignment

The goal is to replace bundix while seamlessly supporting multi-platform gems
with pre-distributed native binaries, using only the Gemfile.lock as source of
truth. The closer we stay to nixpkgs' existing `ruby-modules/` infrastructure,
the less we maintain and the more we benefit from upstream fixes.

8. **Use `bundled-common/functions.nix` instead of reimplementing helpers.**
   nixpkgs already has `filterGemset`, `platformMatches`, `groupMatches`,
   `applyGemConfigs`, and `composeGemAttrs` in
   `pkgs/development/ruby-modules/bundled-common/functions.nix`. Our
   `filter-helpers.nix` reimplements some of these. The upstream versions
   handle edge cases we don't yet (e.g., `platformMatches` checks
   `ruby.rubyEngine` and `version.majMin`, not raw platform strings;
   `groupMatches` always includes `"default"`; `filterGemset` recursively
   expands transitive dependencies via a `converge` fixpoint).

   **Action:** Import and delegate to `bundled-common/functions.nix` where
   possible. Where our behavior intentionally diverges (e.g., platform
   matching by lockfile platform strings rather than Ruby engine), document
   why and keep our version. The functions that are clearly identical
   (`applyGemConfigs`, `groupMatches`) should be dropped in favor of
   upstream.

9. **Use `composeGemAttrs` to assemble `buildRubyGem` inputs.**
   We currently pass a flat attrset to `buildRubyGem` after merging
   checksum data with group info and remotes. Upstream's `composeGemAttrs`
   does this assembly correctly, including:
   - Injecting the `ruby` derivation
   - Setting `gemPath` from resolved transitive dependencies (so native
     extensions can find headers from dependent gems)
   - Setting `type` from `source.type`
   - Passing the `gemName` attribute that `buildRubyGem` expects

   We skip `gemPath` entirely, which means gems with native extensions
   that depend on other gems' headers (e.g., `nokogiri` depending on
   `mini_portile2` at build time) may fail in ways that bundlerEnv doesn't.

   **Action:** Use `composeGemAttrs` or replicate its `gemPath` logic to
   wire up inter-gem build dependencies.

   **Pending test:** `test/unit/test-pending.nix` →
   `test_git_section_records_dependencies`. `gemPath` needs a list of each
   gem's dependencies and we keep none, so that test asks for the missing
   half first: the lockfile already names them on the 6-space lines under
   every gem, and `parseGitSection` currently discards them. See #12 and #14.

   **Confirmed regression (grpc):** `defaultGemConfig` has a `grpc` entry
   with `postPatch` / `substituteInPlace Makefile` intended for source
   compilation. Our `applyGemConfigs` matches by gem name only, so this
   config is blindly applied to the precompiled `grpc-1.78.1-arm64-darwin`
   variant, which has no `Makefile`. Error:
   `substitute(): ERROR: file 'Makefile' does not exist`.

   The config function already receives `attrs` (which includes `platform`),
   so it *could* guard on `attrs.platform == "ruby"`. But neither
   `applyGemConfigs` nor any `defaultGemConfig` entries do this today.

   **Fix options:**
   - Make `applyGemConfigs` skip `defaultGemConfig` entries for non-ruby
     platform gems (precompiled gems shouldn't need source build overrides).
   - Have the config functions themselves check `attrs.platform` and return
     `{}` for precompiled variants.
   - Reorder the pipeline: resolve platforms *before* applying gem configs,
     so only the winning variant gets configured.

   **Regression test:** `test/unit/test-filter.nix` →
   `test_applyGemConfigs_should_respect_platform` (currently fails,
   documenting the bug).

10. **Produce Bundler-aware binstubs like `bundlerEnv` does.**
    Our `buildEnv` creates a flat symlink forest of gems, but doesn't
    generate Bundler-compatible binstubs. Upstream `bundlerEnv` runs
    `gen-bin-stubs.rb` which generates wrappers that call `Bundler.setup()`
    with the correct `GEM_PATH`, `BUNDLE_GEMFILE`, and `BUNDLE_FROZEN=1`.

    Without these, `bundle exec` and Bundler's runtime dependency resolution
    don't work in the Nix environment. Rails apps rely on `Bundler.setup()`
    to activate exactly the right gem versions. A plain `buildEnv` will have
    all gems on the `GEM_PATH` but Bundler won't know about them.

    **This is a hard blocker for git gems, not a refinement.** How much it
    costs you depends on the source:

    - A gem from a `GEM` section survives. `Bundler::Source::Rubygems`
      resolves through `Gem::Specification`, so a gem installed on the
      `GEM_PATH` satisfies it. Apps that boot through `bundler/setup` work
      today because of this.
    - A gem from a `PATH` section survives too. `Bundler::Source::Path`
      reads the gemspec straight out of the source directory. Verified: a
      path gem loads under `bundler/setup` with no `bundle install` first.
    - A gem from a `GIT` section does not. `Bundler::Source::Git#load_spec_files`
      looks only in `GEM_HOME/bundler/gems/<name>-<shortrev>` and never
      consults the `GEM_PATH`. We install git gems as ordinary gems, so
      Bundler cannot see them and raises `Bundler::GitError`.

    So every stock Rails app is shut out of git gems until this item lands.
    Item 13 records the repro and the workaround.

    **Action:** Either call `gen-bin-stubs.rb` in a `postBuild` hook (like
    `bundlerEnv` does), or provide a `confFiles` derivation with the
    Gemfile/Gemfile.lock pair and delegate to upstream's stubs machinery.

11. **Emit a `gemset.nix`-compatible attrset for interop.**
    The parsed gem metadata is close (but not identical) to the
    `gemset.nix` format that `bundlerEnv` and `bundled-common` expect. The
    upstream format is keyed by gem name (not a list), includes a
    `dependencies` field, and uses `platforms` (plural, a list of
    `{ engine, version }` records) rather than `platform` (singular string).

    If we emitted a compatible attrset, users could:
    - Swap between gems4nix and bundlerEnv without changing their Nix code
    - Use `bundlerEnv` directly with our parsed output as the `gemset`
    - Incrementally adopt gems4nix without a hard cutover

    **Action:** Add a `toGemset` function to `parser-helpers.nix` that
    converts our internal representation to the `gemset.nix` format. This
    also serves as a migration path and compatibility layer.

    **Known gap for git sources.** Our `source` attrset for a git gem uses
    upstream's key names (`url`, `rev`, `fetchSubmodules`) and additionally
    records `ref` / `branch` / `tag`, but it has no `sha256`. A Gemfile.lock
    does not contain one and we structurally cannot produce one without
    fetching. Anything consuming our output as a `gemset.nix` will need to
    supply it or use a different fetcher.

12. **Transitive dependency expansion is missing.**
    `bundled-common/functions.nix` has a `converge` fixpoint that expands
    group-filtered gems to include their transitive dependencies (even if
    those deps aren't directly in the requested groups). We don't do this.

    Our `gem-groups.rb` propagates groups downward through the dependency
    tree, which is a different approach: it assigns groups to transitive
    deps so they pass the group filter. The upstream approach keeps the
    gemset's `dependencies` field and expands at filter time.

    The risk: if `gem-groups.rb` misses a transitive dep (as it does with
    `mini_portile2`), that gem gets `groups = []` and is silently dropped
    by `filterGroup`. Upstream's expansion approach would include it because
    it would follow the `dependencies` edges.

    **Action:** Parse the `dependencies` from the `specs:` section of each
    GEM block (they're already in the lockfile: the indented lines under
    each gem). Wire them through to the output, and use converge-style
    expansion instead of relying solely on `gem-groups.rb` for transitive
    group assignment. This also lets us drop the Ruby `runCommand` for
    group extraction if we parse DEPENDENCIES from the lockfile directly.

13. **Git and path sources: done, but NOT via `type = "git"`.**
    The `GIT` and `PATH` lockfile sections are parsed and their gems built.
    The original plan was to hand them to `buildRubyGem` as `type = "git"`
    and to `pathDerivation`. We tried both and rejected both. Neither fits the
    way we build the environment. **Read this before you "fix" it back.**

    We build them as `type = "gem"` with an explicit `src`: a
    `builtins.fetchGit` result, or the resolved store path. `buildRubyGem`'s
    `src` is `attrs.src or (...)`, so supplying it bypasses the fetcher and
    never forces `attrs.source`. With a directory `src`, `unpackPhase`'s
    `*.gem` test fails, it falls through to stdenv's `unpackPhase` and
    re-enables `buildPhase`, so we get `gem build` + `gem install` and a
    standard RubyGems layout that plain `GEM_PATH` can see.

    Why not `type = "git"`:

    - It installs via `nix-bundle-install.rb`, which drives
      `Bundler::Source::Git#install`. That lands the gem in
      `GEM_HOME/bundler/gems/<name>-<shortrev>` with **no
      `specifications/*.gemspec`**. Bundler's `source/path/installer.rb` is
      why: its `post_install` builds extensions and generates binstubs, and
      never calls `write_spec`. RubyGems cannot find the gem via `GEM_PATH`.
      Only `Bundler.setup` or the `nix-support/setup-hook` reaches it.
    - That setup-hook does not survive us: `buildEnv` drops `nix-support`
      outright (`pkgs/build-support/buildenv/builder.pl`, the
      `return if $relName eq "/nix-support"` line). So the gem's files would
      be in the env with nothing able to find them.
    - It also strictly `inherit`s `source.{url,rev,sha256,fetchSubmodules}`,
      and a Gemfile.lock has no sha256.

    **Switching to `type = "git"` requires #10 (Bundler-aware binstubs /
    `Bundler.setup`) as a hard prerequisite.** Do that first or not at all.

    **What we build works for `require`, not for `bundler/setup`.** An early
    draft of this item claimed #10 was not a blocker because we chose
    `type = "gem"`. That claim was wrong and is corrected here. `type = "gem"`
    buys us plain `require` through the `GEM_PATH`, and nothing more. Bundler
    finds a git gem by one path only, `GEM_HOME/bundler/gems/<name>-<shortrev>`,
    which we never write. So an app whose `config/boot.rb` says
    `require "bundler/setup"` — every stock Rails app — still cannot use a git
    gem from us. #10 is not a blocker for *building* a git gem. It is a
    blocker for *consuming* one from a Bundler-booted app.

    Reproduced against `examples/complex`, whose `errgonomic` comes from a
    `GIT` section:

    ```
    # GEM_PATH set, plain require:
    OK plain require errgonomic

    # same environment, via Bundler:
    bundler/source/git.rb:236:in `rescue in load_spec_files':
      https://github.com/omc/errgonomic.git (at main@f06314a) is not yet
      checked out. Run `bundle install` first. (Bundler::GitError)
    ```

    **Workaround until #10 lands: use a `PATH` source instead of a `GIT` one.**
    Bundler reads a path gem's gemspec from its directory, so vendoring the
    gem works under `bundler/setup` with no `bundle install`. Verified. The
    other way out is to publish the gem to a registry and depend on it from a
    `GEM` section.

    Why not `pathDerivation`: it returns a fake derivation whose `outPath` is
    the raw source directory. `bundlerEnv` makes that work with
    `pathsToLink = ["/lib"]`, `confFiles` and binstubs. We have none of those,
    so the gem's `lib/hello_gem.rb` would land at `$out/lib/hello_gem.rb`.
    That is on neither `GEM_PATH` nor `$LOAD_PATH`. (`type = "url"` is not an
    alternative either: `nix-bundle-install.rb` path mode copies nothing into
    `$out`.)

    One more detail that matters: the `preBuild` runs `git init && git add
    -A`, and the build needs it. Many gemspecs list `spec.files` with `git
    ls-files`. Neither a `builtins.fetchGit` result nor a store copy has a
    `.git` directory, so that command returns nothing. The gem then builds
    without error and contains no files, and you learn this from a `require`
    much later. The `postInstall` check looks for the gemspec and for a
    non-empty gem directory, so the build fails instead.

    **Still missing:**
    - A git gem is invisible to `bundler/setup`, as above. #10 is the fix.
      Recorded in `test/unit/test-pending.nix` under `nonTests` as
      `git_gems_are_invisible_to_bundler_setup`.
    - Git gems with native extensions will fail — they need `gemPath` for
      inter-gem build deps (#9). Not exercised by the examples.
    - `builtins.fetchGit` fetches at *evaluation* time and its output is not a
      fixed-output derivation, so no binary cache can serve it. The
      `gemSrcOverrides` argument is the escape hatch for hermetic or offline
      builds.
    - A private repository needs credentials that only the invoking user's git
      configuration supplies. See #15.
    - `glob:` on a GIT or PATH section throws: `buildRubyGem` builds the first
      `*.gemspec` it finds, so a monorepo source would silently build the
      wrong gem. `PLUGIN SOURCE` throws too.
    - `branch:` / `tag:` / `ref:` are parsed and recorded in `source` but not
      fed to `fetchGit`. The output path is determined by `rev` alone
      (verified: adding `ref` or `allRefs` yields an identical store path), so
      they would only change fetch strategy. They are there for #11 interop.
    - Only verified against GitHub. `allRefs = true` is the hedge for servers
      that don't set `uploadpack.allowAnySHA1InWant`.
    - A `gemConfig` entry that sets `src`, `unpackPhase` or `buildPhase` on a
      git/path gem will fight our wrapper. Only `preBuild`, `postInstall`,
      `nativeBuildInputs` and `ruby` are composed; everything else is
      last-writer-wins. Pending test:
      `test_gemconfig_cannot_take_over_a_git_gem_build`, which asks for a throw
      rather than a merge. Two definitions of `src` have no sensible merge.
    - Non-GitHub git servers and the evaluation-time fetch have no test. Both
      are recorded under `nonTests` in `test/unit/test-pending.nix` with the
      reason and what an integration test would need.

14. **The dependency graph is in the lockfile; `gem-groups.rb` is redundant.**
    The `specs:` subsection of each `GEM` block lists every gem's direct
    dependencies. The `DEPENDENCIES` section lists top-level gems and their
    groups. Between these two sections, the entire dependency graph and
    group assignment is recoverable from the lockfile alone, in pure Nix,
    without running Ruby.

    Eliminating the `runCommand` that invokes `gem-groups.rb` would:
    - Remove the Ruby/Bundler build-time dependency from evaluation
    - Make the parser fully pure (no IFD)
    - Speed up `nix eval` by avoiding a derivation build
    - Make the entire pipeline testable without IO

    **Action:** Parse the dependency tree from the `specs:` indentation
    structure (4-space = gem, 6-space = dependency). Parse group membership
    from the `DEPENDENCIES` section. Propagate groups through the dependency
    edges in pure Nix. This is the single highest-leverage change for the
    project's architecture.

15. **A private git gem depends on the invoking user's git configuration.**
    `builtins.fetchGit` shells out to the user's own git. Whatever
    credentials that git can reach, we can reach; whatever it cannot, we
    cannot. This is a real advantage over a fixed-output fetcher, and it is
    also the thing that breaks on a machine nobody configured.

    Measured against a private GitHub repository whose lockfile records an
    `https://` remote:

    - A `url.<ssh>.insteadOf` rewrite works. Git rewrites the https remote to
      ssh and uses the developer's key. This is what a laptop usually has, and
      it is why the fetch looks like it "just works".
    - Without that rewrite, the same https remote fails:
      `fatal: could not read Username for 'https://github.com'`.
    - Nix's `access-tokens` setting does **not** help. It applies to the
      `github:` and `gitlab:` flake input fetchers, not to `builtins.fetchGit`
      on a plain git URL.
    - A credential helper works only if it holds a credential for that host.
      An `osxkeychain` helper with no GitHub entry fails the same way.

    So a CI runner needs its own arrangement: a deploy key plus an `insteadOf`
    rewrite, a netrc or token credential helper, or `gemSrcOverrides` to skip
    the fetch entirely. Check `netrc-file` points somewhere that exists before
    trusting it; a stale path fails silently.

    **Action:** Document the requirement where a user meets it, and consider a
    check that names the missing credential rather than letting git's message
    surface alone. The Readme covers the developer case today.

16. **The lockfile's `RUBY VERSION` is neither read nor enforced.**
    A Gemfile.lock ends with a `RUBY VERSION` section naming the Ruby the
    lockfile was resolved against. We ignore it. The parser has no helper for
    the section, and `gemfileEnv` never compares it to the `ruby` it builds
    with.

    The failure is silent and the versions can drift far apart. A lockfile
    saying `ruby 3.4.9` built against nixpkgs 24.11, whose default is 3.3.5,
    produces a full environment with no warning. Gems resolved for one minor
    version get installed for another, and the first sign of trouble is a
    runtime error in a gem that assumed the newer stdlib.

    **Action:** Parse the section in `parser-helpers.nix` and return it from
    `parseLockfileContent`. Then compare it against `ruby.version` in
    `gemfile-env/default.nix`. Warn rather than throw, at least at first:
    a patch-level disagreement is usually harmless, and a user who knows
    better needs a way past it. A `throw` wants an escape hatch argument
    beside it.

    **Pending test:** `test/unit/test-pending.nix` →
    `test_parseLockfileContent_reads_the_ruby_version`, which asks for the
    parser half. The comparison in `default.nix` has no pure test.

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
    - Git gems with native extensions will fail — they need `gemPath` for
      inter-gem build deps (#9). Not exercised by the examples.
    - `builtins.fetchGit` fetches at *evaluation* time and its output is not a
      fixed-output derivation, so no binary cache can serve it. The
      `gemSrcOverrides` argument is the escape hatch for hermetic or offline
      builds.
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
      git/path gem will fight our wrapper. Only `preBuild`, `postInstall` and
      `nativeBuildInputs` are composed; everything else is last-writer-wins.

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

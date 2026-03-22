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

4. **No support for git or path sources.**
   Gems sourced from git repos or local paths are gracefully skipped by the
   parser (their hashless checksum lines return null) but are not included
   in the built environment. The `examples/complex/` integration test
   documents this: `errgonomic` (git) and `hello_gem` (path) print SKIP
   rather than OK. See also #13.

### Filtering and Building (`default.nix`)

5. **Empty group gems fall through filtering.**
   Gems with `groups = []` (like `mini_portile2`, a build-time dependency)
   are filtered out by `filterGroup` since their intersection with any
   requested groups is empty. This is probably correct, but it means
   build-time dependencies that appear in the lockfile are silently dropped.
   No warning is emitted.

### General

6. **No CI or automated test invocation.**
   Unit tests run via `nix eval`. Integration tests run via
   `nix flake check` in each `examples/` subdirectory. Neither is wired
   into CI yet. A top-level `nix flake check` that runs everything would
   be the next step.

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

13. **`buildRubyGem` can handle git and path sources natively.**
    `buildRubyGem` already supports `type = "git"` (via
    `nix-bundle-install.rb`, which monkey-patches Bundler to install from a
    git checkout) and path sources (via `pathDerivation` in
    `bundled-common/functions.nix`). We don't need to implement these from
    scratch; we just need to parse the `GIT` and `PATH` sections of the
    lockfile and pass the right attributes.

    The lockfile format for git sources is:
    ```
    GIT
      remote: https://github.com/user/repo.git
      revision: abc123
      specs:
        gemname (1.0.0)
    ```

    **Action:** Parse `GIT` and `PATH` sections alongside `GEM` sections.
    For git sources, set `source.type = "git"`, `source.url`, `source.rev`.
    For path sources, set `source.type = "path"`, `source.path`.
    `buildRubyGem` handles the rest.

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

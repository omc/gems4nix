# TODO

> For the latest status, see [GitHub Issues](https://github.com/omc/gems4nix/issues).

## Critiques and Recommendations

### Parser (`parse.nix`, `parse-gemfile-and-lockfile.nix`)

1. **Done. Version-platform splitting parses from the right.**
   `splitVersionPlatform` matches the version token against a list of known Ruby platform strings and strips the matching suffix, rather than splitting on the first `-`. `1.16.0.beta.1-arm64-darwin` and `2.0.0-beta.2-aarch64-linux-gnu` both split correctly, and a token with no known suffix is `platform = "ruby"`. Gated by `test_parseChecksum_beta_version_with_platform`, `test_parseChecksum_prerelease_multi_segment_platform`, and the `splitVersionPlatform` tests in `test/unit/test-parse-logic.nix`.

2. **Open. `takeLines` processes the entire remaining file after `start`.**
   `builtins.foldl'` iterates over every line after the start index, even
   though it stops collecting at the first blank line. For a 1000-line lockfile
   with the CHECKSUMS section at line 745, `takeLines` for the first GEM
   section iterates ~1000 lines. This isn't a correctness bug but is worth
   noting for very large lockfiles.

3. **Done. A gem carries every remote its GEM section declares, and a contested gem is refused.**
   `parseGemSection` reads a section by indent depth: every `  remote:` line is a remote of that section, and only the four-space lines under `specs:` are its gems. Bundler writes several `remote:` lines into one section when a Gemfile declares more than one global source, last-declared-first, which is its own source-priority order; the list keeps that order and `fetchurl` tries the urls in it.

   The six-space dependency lines used to count as gems, which claimed the section's remote for gems another section provides. Measured against `omc/sprout`: its private `depot` section lists `faraday` and six other rubygems.org gems as dependencies, and each of them claimed `rubygems.pkg.github.com`. Nothing broke only because `builtins.listToAttrs` kept the earlier rubygems.org entry — an accident of the order Bundler happened to write the two sections in.

   A gem that two `GEM` sections both claim is now an evaluation error. Bundler locks a resolved gem under the single source that resolved it, so no lockfile it writes has one, and it invents no tie-break for the same ambiguity during resolution: `Bundler::SourceMap#all_requirements` tells the user to name the source in the Gemfile, and raises `SecurityError` in `bundler_4_mode`.

   Gated in `test/unit/test-parse-logic.nix` by `test_parseGemSection_multiple_remotes`, `test_parseGemSection_deps_excluded`, `test_parseGemSection_platform_variants_collapse`, `test_parseGemSection_missing_remote_throws`, `test_parseGemSection_missing_specs_throws`, `test_parseGemSection_unknown_key_throws`, `test_indexRemotes_carries_every_remote` and `test_indexRemotes_duplicate_gem_throws`.

4. **Done. GIT and PATH sections are parsed and built.**
   `parseGitSection` and `parsePathSection` read the two source section types by indent depth, and `mergeGemMetadata` folds their gems into the same list the `CHECKSUMS` gems arrive in. `examples/complex` builds `errgonomic` (git) and `hello_gem` (path) and its validator loads both. See #13 for the build half.

   The parser refuses rather than skipping: a hashless `CHECKSUMS` line no source claims, a `PLUGIN SOURCE` section, a `glob:` option and an unrecognised key on a source section are all evaluation errors. Gated in `test/unit/test-parse-logic.nix` by `test_parseLockfile_unexplained_hashless_throws`, `test_parseLockfile_plugin_source_throws`, `test_parseGitSection_glob_throws`, `test_parsePathSection_glob_throws`, `test_parseGitSection_unknown_key_throws` and `test_parsePathSection_git_key_throws`.

`glob` is listed among each section type's recognised keys precisely so that the two glob tests gate the branch that refuses it. Left off the list, the unrecognised-key branch would reject a glob independently, both tests would pass with the dedicated branch deleted, and this paragraph would be claiming coverage that did not exist. Deleting either branch now fails a test that names it.

At the `gemfileEnv` level the guards are gated by `test/integration/lockfile-guards/guards.nix`.

### Filtering and Building (`default.nix`)

5. **Done. Transitive dependencies survive group filtering.**
   Gems with `groups = []` (like `mini_portile2`, a build-time dependency of ruby-platform nokogiri) used to be dropped by `filterGroup`, producing `Could not find 'mini_portile2' (~> 2.8.2)` during the nokogiri build.

   The pipeline now expands the group-filtered set through the dependency graph parsed from the lockfile's `specs:` section (`expandTransitiveDeps` in `resolve.nix`), before platform filtering, so a kept gem's build-time dependencies are kept whatever their groups.

   **Regression test:** `test/unit/test-resolve-logic.nix` → `test_ruby_only_nokogiri_keeps_build_deps`, now a positive assertion in `allTests`.

### General

6. **Done. `nix flake check` runs the suite in CI.**
   `.github/workflows/ci.yml` runs `nix flake check` on every pull request and on pushes to `main`. The root `checks` output carries the unit suites, the credential, argument and Ruby-override wiring checks, and two `runCommand` integration checks that build real gem environments.

   Two more jobs run beside it. `unit` evaluates the standalone `test/unit/test-*.nix` wrappers, which reach the same logic through an unpinned `fetchTarball` rather than through the flake's `pkgs.lib`. `examples` runs `nix flake check` in each of `examples/{simple,medium,complex}`, which cannot join the root flake: they are standalone flakes with a `path:../..` input, and pulling them in would be a self-reference cycle. CI is `x86_64-linux` only.

   No test gates this one, and none can: what CI runs is evidence produced by a run, not an assertion the suite can make about itself. The seventeen checks `nix flake check` executes are `arguments-strictness`, `bundler-gem-home-guard`, `bundler-git-repo-with-two-gems`, `bundler-layout`, `credentials-wiring`, `git-path-wiring`, `integration-gemspec-directive`, `integration-platform-gems`, `lockfile-guards`, `ruby-override-wiring`, `unit-arguments`, `unit-bundler`, `unit-credentials`, `unit-parse`, `unit-pending`, `unit-pipeline` and `unit-resolve`.

7. **Open. `gem-groups.rb` group propagation may over-propagate.**
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

8. **Open. Use `bundled-common/functions.nix` instead of reimplementing helpers.**
   nixpkgs already has `filterGemset`, `platformMatches`, `groupMatches`,
   `applyGemConfigs`, and `composeGemAttrs` in
   `pkgs/development/ruby-modules/bundled-common/functions.nix`. Our
   `resolve.nix` reimplements some of these. The upstream versions
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

9. **Partly done. `ruby` and the platform guard landed; `gemPath` did not.**
   We still pass a flat attrset to `buildRubyGem` rather than delegating to upstream's `composeGemAttrs`. Of what that function assembles:

   - **Done.** The caller's `ruby` reaches `buildRubyGem`, so the gems and the `GEM_PATH` setup hook are built against the same Ruby. Gated by `test/integration/ruby-override/wiring.nix`.
   - **Done.** `type` and `gemName` come from the parsed metadata.
   - **Open.** `gemPath` is not set. A gem with a native extension that reads another gem's headers at build time (nokogiri wanting `mini_portile2`) does not see its siblings, so it can fail where `bundlerEnv` succeeds. The transitive expansion in #5 puts the sibling in the environment; it does not put it on the building gem's `gemPath`. The edges a fix needs are already parsed: `depGraph` in `default.nix` covers GEM, GIT and PATH sections alike. What is missing is mapping a gem's dependency names to the derivations already built for them. Recorded in `test/unit/test-pending-logic.nix` under `nonTests.native_extensions_cannot_see_their_siblings`.

   **Action for the open half:** use `composeGemAttrs`, or replicate its `gemPath` logic, to wire up inter-gem build dependencies.

   **Fixed regression (grpc):** `defaultGemConfig`'s `grpc` entry carries a `postPatch` with `substituteInPlace Makefile`, intended for source compilation. Applying it by gem name alone reached the precompiled `grpc-1.78.1-arm64-darwin` variant, which has no `Makefile`, producing `substitute(): ERROR: file 'Makefile' does not exist`.

   The pipeline now resolves platform duplicates before applying gem configs, and applies them only when `platform == "ruby"`, so a precompiled variant never receives source-build overrides. Gated by `test_pipeline_precompiled_skips_gemConfig` and `test_pipeline_ruby_only_gets_gemConfig` in `test/unit/test-resolve-logic.nix`. Those tests assert against a local restatement of the pipeline rather than against `default.nix` itself, which is a real gap.

10. **Done, and without binstubs.** `require "bundler/setup"` resolves every source kind, and `bundle exec` runs.

    This item assumed the missing piece was `gen-bin-stubs.rb`. It was not. Bundler needs two things and neither is a binstub: a `GIT`-sourced gem has to sit in `bundler/gems/<repo>-<shortrev>`, and that directory is looked for under `Gem.dir`, so `GEM_HOME` has to name the environment. Each git gem now writes the checkout beside its ordinary install, symlinking its entries and carrying the serialized gemspec out of `specifications/`, and the environment's setup hook exports `GEM_HOME` as well as `GEM_PATH`.

    Binstubs turned out to be unnecessary: the ones `gem install` already writes into each gem's `bin` are on the environment's path, and `bundle exec rake --version` finds one there. `BUNDLE_PATH` is not an alternative to `GEM_HOME`; Bundler appends `ruby/<version>` to it, and the checkout is missed the same way.

    Gated end to end by the `bundler-setup` check in `examples/complex`, which boots through `bundler/setup` against a read-only environment with `BUNDLE_FROZEN=1` and asserts each of the three source kinds resolved through the source its lockfile section names. Gated without the network by `test/integration/bundler-layout/layout.nix` and `test/unit/test-bundler-logic.nix`.

    One limitation remains, recorded in `test/unit/test-pending-logic.nix` under `nonTests.git_gems_with_native_extensions_are_unusable_under_bundler`: Bundler looks for a git gem's compiled extension under the git scope, and RubyGems installs it under the gem's name and version.

11. **Open. Emit a `gemset.nix`-compatible attrset for interop.**
    The parsed gem metadata is close (but not identical) to the
    `gemset.nix` format that `bundlerEnv` and `bundled-common` expect. The
    upstream format is keyed by gem name (not a list), includes a
    `dependencies` field, and uses `platforms` (plural, a list of
    `{ engine, version }` records) rather than `platform` (singular string).

    If we emitted a compatible attrset, users could:
    - Swap between gems4nix and bundlerEnv without changing their Nix code
    - Use `bundlerEnv` directly with our parsed output as the `gemset`
    - Incrementally adopt gems4nix without a hard cutover

    **Action:** Add a `toGemset` function to `parse.nix` that
    converts our internal representation to the `gemset.nix` format. This
    also serves as a migration path and compatibility layer.

12. **Done. Transitive dependency expansion is wired into the pipeline.**
    `parseDependencies` reads the indented dependency lines under each gem in the `specs:` section into a `{ gemName = [ deps ]; }` graph, and `expandTransitiveDeps` closes the group-filtered set over it. `gem-groups.rb` is still what assigns groups; the expansion is what stops a missed transitive dep from being silently dropped, which is the failure in #5.

    Gated in `test/unit/test-parse-logic.nix` by `test_parseDependencies_nokogiri`, `test_parseDependencies_multiple_gems`, `test_parseDependencies_platform_variants_merge`, `test_parseDependencies_no_deps` and `test_parseDependencies_multi_segment_platform`, and in `test/unit/test-resolve-logic.nix` by `test_expandTransitiveDeps_basic`, `test_expandTransitiveDeps_transitive_chain`, `test_expandTransitiveDeps_no_deps`, `test_expandTransitiveDeps_circular`, `test_expandTransitiveDeps_unknown_dep_not_added` and `test_expandTransitiveDeps_empty_initial`. The two halves meeting is what `test_ruby_only_nokogiri_keeps_build_deps` in #5 asserts.

    Dropping the Ruby `runCommand` entirely is a separate change, tracked in #14.

13. **Done, but not the way this item proposed.** `buildRubyGem`'s own `type = "git"` and `pathDerivation` were both rejected.

    `type = "git"` installs the gem into `bundler/gems/` and writes no `specifications/*.gemspec`. That file is what RubyGems reads to find a gem on the `GEM_PATH`, so `require` fails without it. A setup-hook could point at the gem instead, but `buildEnv` deletes the `nix-support` directory a hook lives in. And `type = "git"` wants a `sha256`, which a `Gemfile.lock` does not record for a git source. `pathDerivation` is out for the same gemspec-less reason.

    So a git or path gem builds as `type = "gem"` with a `src` gems4nix supplies: `builtins.fetchGit` at the locked revision, or the resolved path. `gitMinimal` goes on the build path and `preBuild` runs `git init && git add -A`, because many gemspecs compute `spec.files` from `git ls-files` and would otherwise install a gem containing nothing. `postInstall` refuses a gem with no gemspec or an empty gem directory rather than leaving that to fail at `require`.

    A git gem is also given the `bundler/gems/<repo>-<shortrev>` checkout Bundler reads it from, so both `require` and `require "bundler/setup"` find it (#10).

    Three limitations stand, all recorded in `test/unit/test-pending-logic.nix` under `nonTests`. A git gem's compiled extension is installed under a name Bundler does not look for (#10). A git gem with a native extension has no `gemPath` (#9). And `builtins.fetchGit` runs at evaluation time and is not cacheable, for which `gemSrcOverrides` is the escape hatch.

14. **Partly done. The parsers exist; nothing calls them.**
    The `specs:` half is wired: `parseDependencies` feeds the expansion in #12, and it reads every `specs:` block, GIT and PATH sections included, so a git gem's own dependencies survive the group filter too.

    The `DEPENDENCIES` half is written and unit-tested but unreachable from the pipeline. `parseDependenciesSection` and `takeDependenciesSection` in `parse.nix` are exported and covered by `test/unit/test-parse-logic.nix`, and `parse-gemfile-and-lockfile.nix` calls neither. Retiring the IFD means calling them and propagating groups along the `specs:` edges in Nix.

    The rest of this item still stands. Between the two sections, the entire dependency graph and group assignment is recoverable from the lockfile alone, in pure Nix, without running Ruby.

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

# Testing Strategy

## Philosophy

Tests follow a **red-green-refactor** loop:

1. **Red:** Write a test that captures expected behavior. Run it. Watch it
   fail (or verify it passes if testing existing correct behavior). For new
   bug-fix tests, the test should fail against the current code to confirm the
   bug is real before fixing.

2. **Green:** Make the minimal change to pass the test. For tests that
   validate existing correct behavior, this step is already done: the test
   passes on first run, confirming the implementation is correct.

3. **Refactor:** With passing tests as a safety net, improve the code. Rerun
   tests to confirm nothing broke.

## Test Structure

```
lib/gemfile-env/
├── default.nix                        # orchestrator: imports helpers, builds gems
├── parse-gemfile-and-lockfile.nix     # IO shell: readFile, runCommand, delegates to helpers
├── parser-helpers.nix                 # pure: all parsing (line, section, lockfile assembly)
├── filter-helpers.nix                 # pure: filterGroup, filterPlatform, resolvePlatforms
├── gem-groups.rb                      # Ruby script for group extraction
└── gem-dependencies.rb                # (placeholder)

test/
├── test-helpers.nix                   # shared assertEq, assertThrows
├── test.nix                           # integration test (full Rails build)
└── unit/
    ├── test-parser.nix                # unit tests for parser-helpers.nix
    ├── test-filter.nix                # unit tests for filter-helpers.nix
    └── test-pending.nix               # known limitations; fail today, never gated

examples/
├── simple/                            # pure-ruby gems (rack, rake)
│   ├── flake.nix
│   ├── Gemfile
│   ├── Gemfile.lock
│   └── validate.rb
├── medium/                            # native gems (nokogiri, puma, ethon)
│   ├── flake.nix
│   ├── Gemfile
│   ├── Gemfile.lock
│   └── validate.rb
└── complex/                           # Rails 8, git source, path source
    ├── flake.nix
    ├── Gemfile
    ├── Gemfile.lock
    ├── validate.rb
    └── vendor/hello_gem/              # local path gem for testing
```

### Architecture for testability

All pure logic lives in `*-helpers.nix` files that take only `{ lib }` as
input. The production modules (`parse-gemfile-and-lockfile.nix`, `default.nix`)
import these helpers and add IO / nixpkgs build concerns on top. Tests import
the helpers directly to avoid needing `callPackage`, `runCommand`, or Ruby.

Shared assertion functions (`assertEq`, `assertThrows`) live in
`test/test-helpers.nix` and are imported by all unit test files.

### Unit tests

Fast, pure Nix, no network or build. Test individual functions with
synthetic inputs.

- **`test-parser.nix`** -- `findIndices`, `takeLines`, `parseSpecLine`,
  `parseChecksumLine`, `parseGemSection`, `parseSectionBody`,
  `parseGitSection`, `parsePathSection`, `parseLockfileContent`,
  `buildGemRemotes`, `mergeGemMetadata`. Includes tests for malformed input
  (missing hash, extra whitespace, missing sections), the GIT/PATH grammar
  (4-space specs vs 6-space dependency lines, `tag:`/`ref:`/`submodules:`,
  `glob:` and unknown keys throwing), and the anti-silent-skip guards: a
  hashless `CHECKSUMS` entry no GIT/PATH section explains, a `PLUGIN SOURCE`
  section, and GIT/PATH entries leaking into `buildGemRemotes`.

- **`test-filter.nix`** -- `filterGroup`, `filterPlatform`,
  `resolvePlatforms`, `applyGemConfigs`, `platformsForSystem`. Includes
  preference ranking tests (exact arch > compatible > ruby), shadowing bug
  regression, system-to-platform mapping for all four supported systems, and
  characterization tests proving git/path gems pass through the filters
  untouched.

### Characterization vs aspirational tests

A test that asserts behaviour we want but do not have is red forever, which
means it can never gate CI. Known bugs are pinned as *passing* tests that
assert the current wrong behaviour, named and commented to say so, with a
pointer to the TODO entry and instructions to invert them when it lands.
`test_ruby_only_nokogiri_drops_build_deps` (TODO #5) and
`test_filterGroup_git_gem_without_groups` are both of this kind.

### Pending tests (`test/unit/test-pending.nix`)

The other half of that idea. A pending test asserts the behaviour we want,
fails today, and carries a comment saying what a fix would change. Where a
characterization test already pins the same limitation, the two describe it
from both sides, and the pending test names its twin. Some limitations have no
twin, because nothing useful pins them.

Pending tests are in their own file and belong to no `allTests` conjunction, so
nothing runs them by accident. `nix flake check` and CI never see them.

```sh
# list them
nix eval --file test/unit/test-pending.nix --apply 'x: builtins.attrNames x.pending'

# run one; it is expected to fail
nix eval --file test/unit/test-pending.nix pending.test_git_section_records_dependencies

# limitations that have no test, and why
nix eval --file test/unit/test-pending.nix nonTests --json
```

To promote one: make it pass, move it into the `allTests` conjunction of the
file it belongs to, and delete the twin that pinned the old behaviour, if it
names one. Read the whole comment first. Some fixes change the shape of a
parsed gem, and the comment names the gating tests that must change with it.

The same file records limitations that no test can reach, under `nonTests`.
Each entry says what the limitation is, why a test cannot capture it, and what
an integration test would need. Non-GitHub git servers and evaluation-time
fetching are both there. Neither turns on a decision our code makes, so neither
gives a pure test anything to assert.

### Integration tests (`examples/`)

Each example is a self-contained flake with a real Gemfile.lock (with
checksums from rubygems.org), a Ruby validation script, and a `checks`
output. The validation script requires each gem, calls a method to prove the
native extension works, and exits nonzero on failure.

| Example   | Gems | What it exercises |
|-----------|------|-------------------|
| `simple`  | 2 | Basic pipeline: parse, filter, build, load |
| `medium`  | 5 | Native platform variants, group filtering, `defaultGemConfig` |
| `complex` | 60+ | Full Rails, git and path sources, transitive deps |

The complex example is the integration test for git and path sources.
`validate.rb` used to `rescue LoadError` and print SKIP for `errgonomic` (GIT)
and `hello_gem` (PATH), which codified the parser's silent skip as expected
behaviour. That tolerance is gone: both must load or the check fails.

Note that `nix flake check` in `examples/complex` performs a real network fetch
at **evaluation** time, because `builtins.fetchGit` resolves the git gem's
revision during eval. It needs network access and is not served by a binary
cache.

### Integration test (`test/test.nix`)

The original test that evaluates a full `gemfileEnv` against the
`test/rails/` fixture. Validates the end-to-end pipeline including
`gem-groups.rb` group extraction.

## Running Tests

### Unit tests

```sh
nix eval --file test/unit/test-parser.nix --json
nix eval --file test/unit/test-filter.nix --json
```

### Integration tests

```sh
# Individual example
cd examples/simple && nix flake check --no-write-lock-file

# All examples
for ex in simple medium complex; do
  (cd examples/$ex && nix flake check --no-write-lock-file)
done
```

### Everything

```sh
nix eval --file test/unit/test-parser.nix --json && \
nix eval --file test/unit/test-filter.nix --json && \
echo "unit tests passed" && \
for ex in simple medium complex; do
  (cd examples/$ex && nix flake check --no-write-lock-file) || exit 1
done && \
echo "all tests passed"
```

### Red-green-refactor example

```sh
# 1. RED: write a new test case in test/unit/test-parser.nix, then:
nix eval --file test/unit/test-parser.nix --json
# => error: ... (test fails; good, the bug is confirmed)

# 2. GREEN: fix the code in lib/gemfile-env/parser-helpers.nix
nix eval --file test/unit/test-parser.nix --json
# => true (test passes; fix is correct)

# 3. REFACTOR: clean up, then re-run to confirm nothing broke
nix eval --file test/unit/test-parser.nix --json && \
nix eval --file test/unit/test-filter.nix --json && \
echo "all tests still pass"
```

Each `nix eval` returns `true` on success or throws an assertion error with a
descriptive message on failure. No external test harness needed.

## CI

`.github/workflows/ci.yml` runs three jobs on `x86_64-linux`: the root
`nix flake check`, both unit test files, and a matrix over the three examples.

The unit tests are not exposed as root-flake `checks` because they import
nixpkgs through an unpinned `fetchTarball`, which pure flake evaluation
rejects. The examples are not either: each is a standalone flake whose
`gems4nix` input is `path:../..`, so pulling them into the root flake would be
a self-referential cycle. CI therefore runs the same commands documented above,
directly.

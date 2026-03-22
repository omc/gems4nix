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
    └── test-filter.nix                # unit tests for filter-helpers.nix

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

- **`test-parser.nix`** -- `findIndices`, `takeLines`, `parseChecksumLine`,
  `parseGemSection`, `parseLockfileContent`, `buildGemRemotes`,
  `mergeGemMetadata`. Includes tests for malformed input (missing hash,
  extra whitespace, missing sections) and git/path gem handling (hashless
  checksum lines return null).

- **`test-filter.nix`** -- `filterGroup`, `filterPlatform`,
  `resolvePlatforms`, `applyGemConfigs`, `platformsForSystem`. Includes
  preference ranking tests (exact arch > compatible > ruby), shadowing bug
  regression, and system-to-platform mapping for all four supported systems.

### Integration tests (`examples/`)

Each example is a self-contained flake with a real Gemfile.lock (with
checksums from rubygems.org), a Ruby validation script, and a `checks`
output. The validation script requires each gem, calls a method to prove the
native extension works, and exits nonzero on failure.

| Example   | Gems | What it exercises |
|-----------|------|-------------------|
| `simple`  | 2 | Basic pipeline: parse, filter, build, load |
| `medium`  | 5 | Native platform variants, group filtering, `defaultGemConfig` |
| `complex` | 60+ | Full Rails, git/path sources (SKIP until implemented), transitive deps |

The complex example's `validate.rb` uses `rescue LoadError` to SKIP
git/path source gems rather than failing. When TODO #13 is implemented,
those lines will start printing `OK` instead of `SKIP`, no test changes
needed.

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

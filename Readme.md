# gems4nix

Bundle Ruby gems into a Nix environment using Bundler checksums from
`Gemfile.lock` -- no `bundix` or `gemset.nix` needed.

## Quick Start

Add gems4nix to your flake inputs, apply the overlay, and call `gemfileEnv`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=24.11";
    gems4nix = {
      url = "github:omc/gems4nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, gems4nix, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin"; # or your system
        overlays = [ gems4nix.overlays.default ];
      };
      gems = pkgs.gemfileEnv {
        name = "my-app-gems";
        gemfile = ./Gemfile;
        gemfileLock = ./Gemfile.lock;
      };
    in {
      # Use `gems` in buildInputs, set GEM_PATH, etc.
    };
}
```

What it does:

- Parses `Gemfile.lock` (including checksums) in pure Nix
- Resolves platform-specific gem variants for your system (prefers precompiled
  native gems over source compilation)
- Builds each gem with nixpkgs' `buildRubyGem` and combines them into a
  `buildEnv`

## Prerequisites

- **Bundler >= 2.5, with checksums turned on** -- gems4nix reads the SHA256 of every gem from the `CHECKSUMS` section, and no Bundler release writes that section by default. Run `bundle lock --add-checksums` once (or set `BUNDLE_LOCKFILE_CHECKSUMS=true`) and commit the result. Bundler 2.5.22 and 2.7.2 both produce it on request; releases before 2.5 cannot.
- **Platform entries in your lockfile** -- run `bundle lock --add-platform` to
  add precompiled native gem variants for your target systems.

Which platforms to add for which Nix system:

| Nix system | `bundle lock --add-platform ...` |
|---|---|
| `aarch64-darwin` | `arm64-darwin` |
| `x86_64-darwin` | `x86_64-darwin` |
| `aarch64-linux` | `aarch64-linux aarch64-linux-gnu aarch64-linux-musl` |
| `x86_64-linux` | `x86_64-linux x86_64-linux-gnu x86_64-linux-musl` |

To cover all four systems at once:

```sh
bundle lock \
  --add-platform arm64-darwin x86_64-darwin \
  aarch64-linux aarch64-linux-gnu aarch64-linux-musl \
  x86_64-linux x86_64-linux-gnu x86_64-linux-musl
```

## Common Errors and Solutions

**"gems4nix: cannot find CHECKSUMS in Gemfile.lock - run 'bundle lock --add-checksums'"**
Your lockfile has no `CHECKSUMS` section. Bundler does not write one unless asked, so this is the common case for a lockfile that has never been through gems4nix:
```sh
bundle lock --add-checksums
```
If `--add-checksums` is not a recognised flag, your Bundler predates 2.5. Upgrade it with `gem install bundler` and run the command again.

**"Could not find 'mini_portile2'" (or similar build-time dep)**
Your lockfile only has the `ruby` platform, so nokogiri (or similar) is being
compiled from source and needs build-time dependencies that were filtered out.
Add platform entries so the precompiled variant is used instead:
```sh
bundle lock --add-platform arm64-darwin  # (or your platform)
```

**"curl: (22) The requested URL returned error: 401"**
The gem is on a private registry and the build has no credential for it. Declare one with the `credentials` argument. Note that `netrc-file` in `nix.conf` cannot fix this: it configures Nix's own downloader, not the `curl` a derivation runs. See [Private Gem Registries](#private-gem-registries).

**"gems4nix: no credential available for &lt;host&gt;"**
You declared `usernameVar`/`passwordVar` for that host but the variable is empty inside the build. On multi-user Nix the value has to be on the daemon's environment, not your shell. See [Mode 2: from the build environment](#mode-2-from-the-build-environment).

**"gems4nix: cannot read the netrc for &lt;host&gt; at &lt;path&gt;"**
You declared a `netrcFile` the build user cannot read. Absent and unreadable look identical from inside the build, so check both: every directory on the path must be traversable by the build user, and on Linux the path must be in `extra-sandbox-paths`. See [Mode 1: from a file you control](#mode-1-from-a-file-you-control).

**"gems4nix: '&lt;gem&gt;' has no checksum and no GIT/PATH source in the lockfile"**
A `CHECKSUMS` line carries no hash, which means the gem came from a `GIT` or `PATH` section, and no such section in the lockfile provides it. The usual cause is a hand-edited or truncated lockfile. Regenerate it with `bundle lock`. gems4nix refuses rather than dropping the gem, because a dropped gem shows up much later as a `LoadError` naming a layer that is not at fault.

**"gems4nix: PATH source '&lt;dir&gt;' does not exist at &lt;path&gt;"**
A `PATH` section's `remote:` resolved to a directory that is not there. `remote:` is relative to `root`, which defaults to the directory holding the `Gemfile`. If the Gemfile is not co-located with its path gems, pass `root` explicitly. Note that Nix can only see a path inside the flake's source tree.

**"gems4nix: PLUGIN SOURCE sections are not supported"**
Your lockfile has a `PLUGIN SOURCE` section, written by a Bundler plugin that supplies gems from somewhere gems4nix does not know how to fetch. There is no way to build those gems here. Remove the plugin from the `Gemfile` and re-run `bundle lock`, or vendor the gems it provides as a `PATH` source.

**"gems4nix: GIT sources with a 'glob:' option are not supported (remote: &lt;url&gt;)"**
A `GIT` or `PATH` section carries `glob:`, which selects one gemspec out of several in a repository holding more than one gem. `buildRubyGem` builds the first `*.gemspec` it finds and cannot obey the glob, so honouring the section would silently build the wrong gem. Depend on the gem from a registry, or vendor the one subdirectory you want as its own `PATH` source so there is only one gemspec to find.

**"gems4nix: unsupported key '&lt;key&gt;' in GIT section (remote: &lt;url&gt;)"**
A `GIT` or `PATH` section carries an option gems4nix does not recognise. Most such options change which files the gem is built from, so ignoring one means building something other than what the lockfile describes. The recognised `GIT` keys are `remote`, `revision`, `ref`, `branch`, `tag` and `submodules`; a `PATH` section takes `remote` only. If the key is one Bundler genuinely writes, that is a gap worth an issue — quote the section verbatim.

**"Bundler::GitError: ... is not yet checked out. Run `bundle install` first."**
Your app boots through `require "bundler/setup"` and one of its gems comes from a `GIT` section. Bundler looks for a git gem in a directory gems4nix does not write. There is no workaround short of vendoring the gem as a `PATH` source. See [Known Limitations](#known-limitations).

**"could not read Username for 'https://github.com'" while evaluating**
A private `GIT` remote is fetched by `builtins.fetchGit`, which shells out to your own `git`, and https with no credential helper cannot authenticate. A `url."git@github.com:".insteadOf "https://github.com/"` rewrite in your git config works. `credentials` does not apply here: it covers private gem registries, not git remotes.

**"gems4nix: unsupported system '...'"**
The automatic platform detection does not recognize your
`stdenv.hostPlatform.system`. Pass an explicit `platforms` list:
```nix
gemfileEnv {
  # ...
  platforms = [ "ruby" "arm64-darwin" "universal-darwin" ];
};
```

**Build fails for a specific gem**
Some gems need extra build inputs or patches. Check whether
`nixpkgs.defaultGemConfig` already has an override for that gem. If not, supply
one via `gemConfig`:
```nix
gemfileEnv {
  # ...
  gemConfig = pkgs.defaultGemConfig // {
    my-gem = attrs: {
      buildInputs = [ pkgs.openssl ];
    };
  };
};
```

**"gems4nix: Gemfile uses the `gemspec` directive but no gemspec was supplied"**
Your Gemfile calls `gemspec` (the default `bundle gem` layout). Group inference
runs Bundler against a sandboxed Gemfile, so the `.gemspec` — and anything it
`require_relative`s — must be handed to `gemfileEnv` explicitly:
```nix
gemfileEnv {
  # ...
  gemspec    = ./my-gem.gemspec;
  extraFiles = {
    "lib/my_gem/version.rb" = ./lib/my_gem/version.rb;
  };
};
```
Alternatively, pass an explicit `gemGroups = { name = [ "default" ]; ... }`
mapping to skip Bundler group inference entirely.

## How It Works

The pipeline has three stages:

1. **Parse** (`parse.nix`) -- reads `Gemfile.lock` in pure Nix and produces a
   list of gem attribute sets with name, version, platform and source. A gem
   from a `GEM` section carries its remote and its SHA256 from the `CHECKSUMS`
   section; a gem from a `GIT` or `PATH` section carries the revision or the
   directory to build from instead.

2. **Resolve** (`resolve.nix`) -- filters gems by requested groups and target
   platforms, expands transitive dependencies, and resolves each gem name to
   exactly one variant (preferring precompiled native over ruby-platform).

3. **Build** (`default.nix`) -- applies `gemConfig` overrides (only to
   ruby-platform gems), calls `buildRubyGem` for each resolved gem, and
   combines them into a `buildEnv`.

### Platform resolution

Many gems ship precompiled native variants alongside a pure-ruby fallback.
The lockfile CHECKSUMS section lists all of them:

```
nokogiri (1.18.8) sha256=8c7464...          # pure ruby
nokogiri (1.18.8-arm64-darwin) sha256=483b...  # precompiled for Apple Silicon
nokogiri (1.18.8-x86_64-linux-gnu) sha256=4a7... # precompiled for x86 Linux
```

gems4nix narrows this down in three steps, matching what `bundle install` does:

1. **Filter by platform.** Keep only variants whose platform is in the accepted
   set for this system. On `aarch64-darwin` that is
   `["ruby" "arm64-darwin" "universal-darwin"]`.

2. **Prefer native over ruby.** If both `arm64-darwin` and `ruby` variants
   survive, pick the native one. This avoids source compilation.

3. **One gem per name.** After resolution each gem name maps to exactly one
   derivation.

### Git and path gem sources

A `Gemfile` entry with `git:`, `github:` or `path:` puts a `GIT` or `PATH` section at the top of the lockfile, and the gem gets a `CHECKSUMS` line with no hash:

```
GIT
  remote: https://github.com/omc/errgonomic.git
  revision: f06314af89209f855019219fd198513855be0fd5
  branch: main
  specs:
    errgonomic (0.5.1)
      concurrent-ruby (~> 1.0)

PATH
  remote: vendor/hello_gem
  specs:
    hello_gem (0.1.0)
```

Both build with no extra configuration. A git gem is fetched by `builtins.fetchGit` at the pinned revision; a path gem is built from `root + "/" + remote`, where `root` defaults to the directory holding the `Gemfile`. Either way the result is an ordinary gem on the `GEM_PATH`, so `require` finds it.

Because `builtins.fetchGit` runs while Nix evaluates, and its result is not something a binary cache can serve, `gemSrcOverrides` replaces the source of a named gem with one you fetch yourself:

```nix
gemfileEnv {
  name = "app-gems";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;

  gemSrcOverrides.errgonomic = pkgs.fetchFromGitHub {
    owner = "omc";
    repo = "errgonomic";
    rev = "f06314af89209f855019219fd198513855be0fd5";
    hash = "sha256-...";
  };
}
```

The value can also be a function, which receives the gem's parsed `source` and returns the `src` to use. Naming a gem with no `GIT` or `PATH` source is an evaluation error, so a misspelled name fails loudly rather than falling back to the network fetch you were avoiding.

`root` must be a Nix **path**, not a string. A `.` or `..` in a `remote:` is resolved by path arithmetic, and a string is never copied into the store. The default — the directory holding the `Gemfile` — is wrong in one common case: a `Gemfile` generated with `writeText` lives in `/nix/store`, and every path remote would then resolve against that. Pass `root` explicitly there:

```nix
gemfileEnv {
  name = "app-gems";
  gemfile = pkgs.writeText "Gemfile" gemfileText;
  gemfileLock = ./Gemfile.lock;
  root = ./.;
}
```

A `PATH` source that does not exist under `root` is an evaluation error naming `root`, not a silent skip.

### Git gems do not work under `require "bundler/setup"`

Read this before putting a git gem in a Rails app.

gems4nix installs a git gem as an ordinary gem, so plain `require` finds it through the `GEM_PATH`. Bundler does not. `Bundler::Source::Git` looks for a git gem in `bundler/gems/<name>-<shortrev>` under Bundler's install path — `GEM_HOME` unless `BUNDLE_PATH` says otherwise — and nowhere else. So an app that boots with `require "bundler/setup"`, which is every stock Rails app, fails on the git gem:

```
bundler/source/git.rb:236:in `rescue in load_spec_files':
  https://github.com/omc/errgonomic.git (at main@f06314a) is not yet
  checked out. Run `bundle install` first. (Bundler::GitError)
```

That transcript is bundler 2.5.22; the line number moves between releases, and the raise sits in `load_spec_files` either way.

Gems from `GEM` and `PATH` sections are unaffected. Bundler resolves a rubygems gem through `Gem::Specification`, which reads the `GEM_PATH`, and it reads a path gem's gemspec straight out of its directory. Only `GIT` sources break.

Until this is fixed, vendor the gem and depend on it as a `PATH` source, or publish it to a registry. A vendored path gem loads under `bundler/setup` with no `bundle install`.

A lockfile gems4nix cannot honour is an evaluation error rather than a gem missing from the environment: a hashless `CHECKSUMS` line no source claims, a `PLUGIN SOURCE` section, a `glob:` option, and any unrecognised key on a `GIT` or `PATH` section all throw and name what they found. Each has its own entry under [Common Errors and Solutions](#common-errors-and-solutions), with the message as thrown and what to do about it.


## Configuration

`gemfileEnv` accepts these parameters:

| Parameter | Default | Description |
|---|---|---|
| `name` | (required) | Name for the resulting derivation |
| `gemfile` | (required) | Path to `Gemfile` |
| `gemfileLock` | (required) | Path to `Gemfile.lock` |
| `groups` | `["default" "development" "production" "test"]` | Which Bundler groups to include |
| `platforms` | auto-detected from `stdenv` | List of Bundler platform strings |
| `gemGroups` | auto-detected via `gem-groups.rb` | Attrset of `{ gemName = [ "group1" ... ]; }` to override group detection |
| `gemspec` | `null` | Path to the `*.gemspec` when the Gemfile uses the `gemspec` directive |
| `extraFiles` | `{}` | `{ "relative/dest" = ./src; }` — files the gemspec reads at load time |
| `gemConfig` | `nixpkgs.defaultGemConfig` | Per-gem build overrides |
| `credentials` | `{}` | Private registry credentials keyed by remote host; each entry is `{ netrcFile }` or `{ usernameVar, passwordVar }` |
| `root` | directory holding the `Gemfile` | Directory that `PATH` source `remote:` values resolve against |
| `gemSrcOverrides` | `{}` | `{ gemName = src-or-function; }` — replaces the source of a git or path gem |
| `ruby` | `nixpkgs.ruby` | Ruby derivation the gems and `GEM_PATH` are both built against |
| `debug` | `false` | Trace each gem as it is built |

This table is the whole argument surface. Anything else is an evaluation error naming the argument, so repinning to a version that predates a feature fails at the call site rather than succeeding and ignoring it.

### Group filtering example

```nix
gemfileEnv {
  name = "prod-gems";
  gemfile = ./Gemfile;
  gemfileLock = ./Gemfile.lock;
  groups = [ "default" "production" ];
};
```

Group extraction uses a Ruby IFD (`gem-groups.rb`) by default. To avoid IFD,
pass `gemGroups` explicitly.

## Private Gem Registries

A gem hosted on a private registry needs a credential inside the Nix build sandbox. Declare one per remote host. gems4nix does not care where the secret comes from, because the two available answers fail on different machines, so pick the one that fits yours.

The key is a bare host, matched against the remote each gem is fetched from. Gems on remotes you did not name are fetched unauthenticated, exactly as before. If you name a host no gem uses, gems4nix warns. That is almost always a typo.

Either way the secret stays out of the Nix store: gems4nix writes a netrc into the build directory, which is discarded with the build.

### Mode 1: from a file you control

```nix
credentials."rubygems.pkg.github.com".netrcFile = "/run/secrets/gem-registry-netrc";
```

The file is an ordinary netrc:

```
machine rubygems.pkg.github.com login your-username password ghp_…
```

`netrcFile` must be a **string**, not a Nix path literal. A path literal would copy the file into the store; a string is read at build time and never copied. gems4nix rejects a path literal rather than letting it through.

Two requirements, both of which produce a named error rather than a 401 if unmet:

- **The build user must be able to read it.** The build does not run as you. Under a multi-user daemon it runs as a build user sharing no group with you, so a secret under a `0750` home directory is unreachable no matter its own mode. Grant it to the build group instead of the world.
- **On Linux, the sandbox must expose it.** `extra-sandbox-paths = /run/secrets/gem-registry-netrc`. Darwin defaults to `sandbox = false`, so ordinary Unix permissions are the only gate there.

This mode needs no daemon configuration at all.

### Mode 2: from the build environment

```nix
credentials."rubygems.pkg.github.com" = {
  usernameVar = "GEM_REGISTRY_USER";
  passwordVar = "GEM_REGISTRY_TOKEN";
};
```

gems4nix names both variables in the fetch derivation's `impureEnvVars`. Nix reads those from the environment of the process that runs the build, which on multi-user Nix is `nix-daemon`, not your shell: `export GEM_REGISTRY_TOKEN=…` before `nix build` has no effect. The variables have to be on the daemon's job, and it needs a restart to pick them up. On single-user Nix the build runs as you, so exporting them in the invoking shell is enough.

This mode needs no readable file anywhere, which is its advantage. Its cost is that populating the daemon's environment is machine-level configuration nothing in your project can express.

**Do not set the value directly in `nix.envVars`.** That option is the obvious-looking route and it is the wrong one: NixOS and nix-darwin render the value into the generated unit or plist, which lands in the Nix store at mode `0444`. The token becomes readable by every local user and every process, permanently. Feed the daemon's environment from a file instead — see below.

### Using a secret manager

Both modes work with [sops-nix](https://github.com/Mic92/sops-nix), which decrypts secrets at activation into `/run/secrets` rather than into the store.

For **mode 1**, decrypt the netrc and make it readable by the build group. Nix builds run as `_nixbld*` in group `nixbld`, so `0440` with that group keeps the file off world-readable paths:

```nix
sops.secrets."gem-registry-netrc" = {
  sopsFile = ./secrets/gem-registry-netrc;
  format = "binary";
  group = "nixbld";
  mode = "0440";
};
```

Then point gems4nix at `config.sops.secrets."gem-registry-netrc".path`, and on Linux add that path to `nix.settings.extra-sandbox-paths`.

For **mode 2** on NixOS, render an environment file and hand it to the daemon unit, so the value reaches the daemon's environment without ever being written to the store:

```nix
sops.templates."nix-gem-registry.env".content = ''
  GEM_REGISTRY_USER=${config.sops.placeholder."gem-registry-user"}
  GEM_REGISTRY_TOKEN=${config.sops.placeholder."gem-registry-token"}
'';

systemd.services.nix-daemon.serviceConfig.EnvironmentFile =
  config.sops.templates."nix-gem-registry.env".path;
```

There is no launchd equivalent of `EnvironmentFile`, so mode 2 on darwin means wrapping the daemon's `ProgramArguments` to source the file before `exec`ing `nix-daemon`. Mode 1 is the simpler fit on darwin.

### Why not `NIX_CURL_FLAGS`

The workaround people usually arrive at is a netrc on disk plus `NIX_CURL_FLAGS=--netrc-file /etc/nix/netrc` on the daemon. It works. Its cost is easy to miss: `NIX_CURL_FLAGS` has to be set on the daemon *and* the file has to be readable by the build user, and because the flag is set machine-wide rather than per fetch, the file it names is conventionally `/etc/nix/netrc` at mode `0644`. Every local user can then read the registry token.

| | `NIX_CURL_FLAGS` + netrc | `netrcFile` | `usernameVar` / `passwordVar` |
| -- | -- | -- | -- |
| needs the daemon environment | yes | **no** | yes |
| needs a readable secret on disk | yes | yes | **no** |
| can be scoped to the build group | in principle | **yes** | n/a |
| declared in the derivation | no | **yes** | **yes** |
| secret in the store | no | no | no |
| scoped to the hosts that need it | no | **yes** | **yes** |

All three keep the secret out of the store. What `credentials` adds is that the requirement is stated where the fetch happens, scoped to the hosts that need it, and reported by name when it is missing.

### `netrc-file` in `nix.conf` does not apply

`netrc-file` configures Nix's own downloader: substituters, flake inputs, `builtins.fetchurl`. A derivation that runs its own `curl` never consults it. This is why a private `github:` flake input resolves on a machine where a gem fetch still returns 401. Being in `trusted-users` does not help either; that governs which settings a client may send to the daemon.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run tests, add fixtures, and
contribute code. See [ARCHITECTURE.md](ARCHITECTURE.md) for a one-page project
map.

## Known Limitations

- **A git gem is invisible to `require "bundler/setup"`.** gems4nix installs it as an ordinary gem, so plain `require` finds it on the `GEM_PATH`. Bundler looks for a git gem in `bundler/gems/<name>-<shortrev>` under its own install path, which gems4nix never writes, and raises `Bundler::GitError: ... is not yet checked out. Run 'bundle install' first.` Every stock Rails app boots that way. Gems from `GEM` and `PATH` sections are unaffected; vendoring the gem as a path source is the workaround.
- **A git gem with a native extension cannot see its build-time siblings.** `buildRubyGem` takes those through `gemPath`, and gems4nix does not set it. This is not specific to git gems, but a git gem is where it bites first.
- **`builtins.fetchGit` runs at evaluation time.** Any command that evaluates an output holding a git gem needs the network then, and needs credentials then for a private repository. The result is not a fixed-output derivation, so no binary cache can serve it. `gemSrcOverrides` is the way out.
- **A private git remote depends on the invoking user's git configuration**, which is a different axis from `credentials` above. `credentials` covers private *registries* fetched over `fetchurl`; a git remote is fetched by the user's own `git`. A `url.<ssh>.insteadOf` rewrite works. A bare https remote fails with `could not read Username`. Nix's `access-tokens` and `netrc-file` settings configure Nix's downloader, not this `git`, so neither applies.
- **`branch:`, `tag:` and `ref:` are recorded and never used.** The fetch goes by revision alone, which is what determines the store path, so adding any of them would return the identical result.
- **A path gem must live inside the flake's source tree.** Its `remote:` resolves against `root`, and Nix can only copy a source it can see.
- **Only GitHub git remotes have been tried.** A locked revision is often not a branch tip, and a server with `uploadpack.allowAnySHA1InWant` off refuses to send one on its own; gems4nix asks for every ref to work around that.
- **Bundler >= 2.5 is required**, and its `CHECKSUMS` section has to be enabled explicitly with `bundle lock --add-checksums`.
- **Group extraction uses Ruby IFD** by default. This is an impurity at Nix
  evaluation time. Pass `gemGroups` to avoid it.

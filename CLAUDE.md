# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

FlightDeck is an i3-like tiling window manager for macOS, written in Swift. It is a fork of
[AeroSpace](https://github.com/nikitabobko/AeroSpace). It is distributed as a Developer ID-signed,
Apple-notarized app bundle through the Homebrew tap `saadjs/homebrew-tap`
(`brew install --cask saadjs/tap/flightdeck`).

**AeroSpace compatibility is a deliberate project goal.** Configs still load from `~/.aerospace.toml` /
`${XDG_CONFIG_HOME}/aerospace/aerospace.toml`, `AEROSPACE_*` callback env vars are preserved, and the
TOML config format is unchanged. The user-facing CLI/app are renamed to `flightdeck` / `FlightDeck.app`
(bundle id `sh.saad.flightdeck`). Avoid breaking config format, CLI behavior, or runtime behavior.

## Architecture

**Client/server split.** The `flightdeck` CLI binary is a thin **client**; `FlightDeck.app` is the
**server**. They communicate over a UNIX socket. For normal commands, the client parses args (reporting
parse errors / `--help` locally), sends the original args to the server, the server re-parses and
executes them, and returns stdout/stderr/exit code. `true`, `false`, `--version`, and streaming
`subscribe` have special client-side paths.

**Source layout** (`Sources/`, an SPM package defined by `Package.swift`):
- `AppBundle/` — the server. An SPM *library* (SPM can't build macOS app bundles) consumed by the Xcode
  app target. Subsystems: `command/` (command impls + parsing), `config/` (TOML config parsing &
  hot-reload), `tree/` (window/container tree model), `layout/`, `model/`, `mouse/`, `ui/` (SwiftUI menu
  bar / message windows), plus `server.swift`, `runLoop.swift`, `focus*.swift`.
- `Cli/` — the CLI client. Pure SPM, no Xcode. Entry point `_main.swift`.
- `AeroSpaceApp/AeroSpaceApp.swift` — `@main` SwiftUI `App` entry point for the bundle; calls
  `initAppBundle()`. Shared between SPM and the Xcode project.
- `Common/` — code shared between client and server: command-line arg parsing (`cmdArgs/`), models,
  utils, app metadata.
- `AppBundleTests/` — tests.
- `PrivateApi/` — minimal C interop for private macOS APIs.

**Debug vs release build.** Debug builds use SPM only (`swift build`, no Xcode). The release app bundle
is built with Xcode via `xcodebuild`, using `AeroSpace.xcodeproj` which is **generated** from
`project.yml` by XcodeGen (run through `generate.sh`). Open `Package.swift` (not the `.xcodeproj`) in
Xcode/LSP — the `.xcodeproj` exists only for release builds.

## Generated files — `generate.sh`

Several committed files are generated and **must stay in sync with their sources**, or tests/release
builds fail. `generate.sh` produces:
- `Sources/Common/versionGenerated.swift` and `gitHashGenerated.swift` (version + git hash; SNAPSHOT by default)
- committed CLI help sources plus ignored man-page output (`.man/`) from `docs/commands.mdx` —
  **requires Node.js**
- the Xcode project (XcodeGen)

`docs/commands.mdx` is the **source of truth** for CLI help and man pages — edit it, then regenerate.
Shell completions are separate: `build-shell-completion.sh` generates ignored `.shell-completion/`
output from `grammar/commands-bnf-grammar.txt`.

`test.sh` starts and ends with a clean-worktree gate, and `build-release.sh` checks after its initial
generation pass. `script/check-uncommitted-files.sh` fails for **any** tracked or untracked change, not
only stale generated files. Commit or stash all changes before running `test.sh` or a release build.

## Common commands

```sh
./build-debug.sh                # SPM debug build → .debug/ (flightdeck + AeroSpaceApp)
./test.sh                       # full check: debug build (warnings-as-errors), swift tests,
                                #   --help/--version smoke tests, lint, generate + uncommitted-files gate
./swift-test.sh                 # swift tests only
swift test --filter FocusCommandTest   # run a single test suite/case
./lint.sh                       # swiftformat + swiftlint --fix, then periphery (dead-code) scan
./format.sh                     # swiftformat + swiftlint --fix only
./run-debug.sh [args]           # build + run the debug app (.debug/AeroSpaceApp)
./run-cli.sh <subcommand>       # build + run the flightdeck CLI client against a running server
./build-docs.sh man             # regenerate man pages from docs/commands.mdx
./build-shell-completion.sh     # regenerate zsh/fish/bash completions (requires Rust, bash 5, fish)
cd docs && npm run dev          # preview the Mintlify docs site
cd docs && npm run validate && npm run broken-links   # validate docs
```

Tooling (swiftformat, swiftlint, periphery, xcodegen) is auto-installed into `.deps/` by
`script/install-dep.sh`. Swift toolchain version is pinned in `.swift-version`.

## Adding/changing a command — checklist

1. Update docs in `docs/commands.mdx` (source of truth for help + man pages), then `./generate.sh`.
2. Consider whether `--window-id` and/or `--workspace` flags apply.
3. Update shell completion grammar in `grammar/commands-bnf-grammar.txt`, then run
   `./build-shell-completion.sh`.
4. Validate docs (`cd docs && npm run validate && npm run broken-links`) and check `.man/` output.

## Release process

Releases are built locally (there is no release CI). The release build version is supplied explicitly with
`--build-version`; the FlightDeck release tag is created manually after building. Nothing is hardcoded in
committed generated version files. For an upstream-synced release, use the AeroSpace numeric version as the
build version and a distinct FlightDeck tag (for example, build `0.21.2` from `v0.21.2-Beta` and tag it
`flightdeck-v0.21.2-beta.1`) so tags from the two remotes never collide.

Prerequisites: Developer ID Application signing identity in the keychain, a notary keychain profile
(default `flightdeck-notary`), Xcode 26+, Node.js, Rust/cargo, Bash 5 available on `PATH` (for example,
Homebrew's `/opt/homebrew/bin/bash`), fish,
and a local clone of the Homebrew tap at `$HOME/src/homebrew-tap` (override via
`FLIGHTDECK_HOMEBREW_TAP_PATH`).

**Runbook — `script/release-local.sh`** does tests → `build-release.sh --notarize` (universal arm64+x86_64
build, sign, notarize, staple, pack `FlightDeck-vX.Y.Z.zip`) → generates the brew cask with the GitHub
release URL → copies it into `<tap>/Casks/<cask-name>.rb`. It stops there and prints the remaining steps.

```sh
./script/release-local.sh \
  --build-version X.Y.Z \
  --upstream-tag vX.Y.Z-Beta \
  --release-tag flightdeck-vX.Y.Z-beta.1 \
  --cask-name flightdeck-beta
```

Then the **manual, outward-facing** steps (irreversible):
1. Tag the built commit: `git tag flightdeck-vX.Y.Z-beta.1 && git push origin flightdeck-vX.Y.Z-beta.1` (must be the exact commit that was
   built — the binary embeds `git rev-parse HEAD` and the build verifies it).
2. `gh release create flightdeck-vX.Y.Z-beta.1 .release/FlightDeck-vX.Y.Z.zip --prerelease` — the zip name must match the cask URL
   (`.../releases/download/flightdeck-vX.Y.Z-beta.1/FlightDeck-vX.Y.Z.zip`); the cask `sha256` was computed from this zip.
3. Commit and push the updated cask in the tap repo (for this prerelease, `Casks/flightdeck-beta.rb`).

Notes: `build-release.sh --skip-notarization` (or omitting `--notarize`) builds without notarizing for
local testing. `install-from-sources.sh` installs a local `flightdeck-dev` cask (work in progress).

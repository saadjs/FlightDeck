---
name: flightdeck-upstream-release
description: Sync FlightDeck with released AeroSpace versions and run the matching FlightDeck release process. Use when checking whether AeroSpace has a new release, planning or applying an upstream sync, aligning FlightDeck version and tag numbers, validating a sync, notarizing, publishing a GitHub prerelease, or updating the FlightDeck Homebrew tap.
---

# FlightDeck Upstream Release

Operate from the FlightDeck repository. Treat `UPSTREAM_RELEASE`, `AGENTS.md`, and the release scripts as the source of truth. Preserve unrelated work in a dirty worktree.

## Gate and plan

1. Fetch `origin` and `upstream`. Use `gh release view` to identify the newest **published** AeroSpace release; do not sync an arbitrary upstream branch tip.
2. Compare that tag with `UPSTREAM_RELEASE`, FlightDeck's latest release, and the commit divergence. If no newer published AeroSpace release exists, report that and stop.
3. Before editing, report the proposed upstream tag, version/tag mapping, expected conflict areas, test plan, and the stable-versus-beta cask decision.

## Sync a released upstream tag

1. Validate and fetch the tag, advancing only the pristine tracking branch when it is fast-forwardable:

   ```sh
   ./script/sync-upstream-release.sh \
     --upstream-tag vX.Y.Z-Beta \
     --update-tracking-ref
   ```

2. Create a clearly named FlightDeck branch, such as `sync-aerospace-vX.Y.Z-beta`; do not use the literal AeroSpace tag as a FlightDeck release tag.
3. Merge the validated upstream tag explicitly. Keep FlightDeck branding, bundle identifiers, signing/notarization, and Mintlify documentation unless the user directs otherwise. Resolve conflicts deliberately and update `UPSTREAM_RELEASE` with the upstream tag and commit.
4. Update docs, completion/manpage coverage, release instructions, and generated expectations when upstream commands or configuration change.

FlightDeck `main` is an overlay fork and normally cannot fast-forward from upstream. Keep `upstream-release` pristine and fast-forwardable; merge or rebase the FlightDeck overlay separately.

## Version rules

- Set `--build-version` to the numeric AeroSpace release version: `v0.21.2-Beta` becomes `0.21.2`. This supplies the macOS app's numeric `CFBundleShortVersionString`, so do not pass `-Beta` to `--build-version`.
- Use a distinct FlightDeck release tag. For an upstream prerelease, use `flightdeck-v0.21.2-beta.1`; never reuse the upstream tag because Git tags share a namespace.
- Use `flightdeck-beta` for prereleases and `flightdeck` only for stable upstream releases. A lower upstream-aligned beta version can require existing beta users to uninstall and reinstall rather than upgrade.

## Validate before publication

Run the project checks appropriate to the change, including:

```sh
./test.sh
./script/check-docs.sh
./build-release.sh --build-version X.Y.Z --skip-notarization
```

Confirm the universal app and CLI are strictly signed, embed `git rev-parse HEAD`, and that the generated cask SHA-256 matches the ZIP. Commit and push all release-affecting repository changes, then rebuild from the exact commit that will be tagged.

## Notarize and publish

Require explicit user approval before Apple submission, GitHub release creation, or tap publication. Run the release wrapper from a clean, pushed release commit:

```sh
./script/release-local.sh \
  --build-version X.Y.Z \
  --upstream-tag vX.Y.Z-Beta \
  --release-tag flightdeck-vX.Y.Z-beta.1 \
  --cask-name flightdeck-beta
```

It runs tests, notarizes and staples the build, packages the ZIP, and writes the generated cask to `$HOME/src/homebrew-tap` (or `FLIGHTDECK_HOMEBREW_TAP_PATH`). Do not tag or publish if it fails.

After it succeeds:

1. Confirm Apple notarization is Accepted and validate the signed artifact where the environment permits.
2. Tag the exact built commit and push the tag.
3. Create a GitHub prerelease with `gh release create --verify-tag --prerelease` and upload the ZIP.
4. Verify the uploaded asset digest equals the cask SHA-256 and that the cask URL resolves to the release tag.
5. Commit and push only the selected cask in `saadjs/homebrew-tap`.

Report the upstream tag, FlightDeck release URL, release commit, notarization status, cask/tap commit, test results, and any beta migration instruction. Leave the stable cask untouched for an upstream prerelease.

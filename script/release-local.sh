#!/usr/bin/env bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

build_version=""
cask_version=""
upstream_tag=""
release_tag=""
tap_git_repo_path="${FLIGHTDECK_HOMEBREW_TAP_PATH:-$HOME/src/homebrew-tap}"
team_id="${FLIGHTDECK_TEAM_ID:-2ZPA772V9V}"
codesign_identity="${DEVELOPER_ID_APPLICATION:-}"
notary_profile="${FLIGHTDECK_NOTARY_PROFILE:-flightdeck-notary}"
run_tests=1
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --cask-version) cask_version="$2"; shift 2;;
        --upstream-tag) upstream_tag="$2"; shift 2;;
        --release-tag) release_tag="$2"; shift 2;;
        --tap-git-repo-path) tap_git_repo_path="$2"; shift 2;;
        --team-id) team_id="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        --notary-profile) notary_profile="$2"; shift 2;;
        --skip-tests) run_tests=0; shift 1;;
        *) echo "Unknown option $1" >&2; exit 1;;
    esac
done

if test -z "$codesign_identity"; then
    codesign_identity="Developer ID Application: Saad Bash ($team_id)"
fi

if test -z "$build_version"; then
    echo "--build-version flag is mandatory" >&2
    exit 1
fi
if ! [[ "$build_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "--build-version must be a numeric X.Y.Z version" >&2
    exit 1
fi

if test -n "$upstream_tag"; then
    upstream_build_version=${upstream_tag#v}
    upstream_build_version=${upstream_build_version%%-*}
    upstream_cask_version=${upstream_tag#v}
    if test "$build_version" != "$upstream_build_version"; then
        echo "--build-version ($build_version) must match the numeric version in --upstream-tag ($upstream_tag)" >&2
        exit 1
    fi
    if test -n "$cask_version" && test "$cask_version" != "$upstream_cask_version"; then
        echo "--cask-version ($cask_version) must match --upstream-tag without its v prefix ($upstream_cask_version)" >&2
        exit 1
    fi
    cask_version="$upstream_cask_version"
    if ! git merge-base --is-ancestor "$upstream_tag" HEAD; then
        echo "--upstream-tag ($upstream_tag) must be merged into the release commit" >&2
        exit 1
    fi
fi

if test -z "$cask_version"; then cask_version="$build_version"; fi

if test -z "$release_tag"; then
    if test -n "$upstream_tag"; then
        release_tag="flightdeck-$upstream_tag"
    else
        release_tag="flightdeck-v$build_version"
    fi
fi
if test "$release_tag" = "$upstream_tag"; then
    echo "--release-tag must be distinct from --upstream-tag to avoid Git tag collisions" >&2
    exit 1
fi
cask_name="flightdeck"

if ! test -d "$tap_git_repo_path/Casks"; then
    echo "--tap-git-repo-path must point to a Homebrew tap with a Casks directory" >&2
    exit 1
fi

if test "$run_tests" = 1; then
    ./test.sh
fi

./build-release.sh \
    --build-version "$build_version" \
    --cask-version "$cask_version" \
    --team-id "$team_id" \
    --codesign-identity "$codesign_identity" \
    --notary-profile "$notary_profile" \
    --notarize

release_zip="FlightDeck-v$build_version.zip"
release_url="https://github.com/saadjs/FlightDeck/releases/download/$release_tag/$release_zip"

./script/build-brew-cask.sh \
    --cask-name "$cask_name" \
    --zip-uri ".release/$release_zip" \
    --cask-zip-uri "$release_url" \
    --build-version "$build_version" \
    --cask-version "$cask_version"

cp -r ".release/$cask_name.rb" "$tap_git_repo_path/Casks/$cask_name.rb"

echo
echo "Release artifact: .release/$release_zip"
echo "Tap cask: $tap_git_repo_path/Casks/$cask_name.rb"
echo "Upload .release/$release_zip to $release_url before pushing the tap update."
echo "Tag the built commit with: git tag $release_tag && git push origin $release_tag"

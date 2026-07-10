#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

upstream_remote=upstream
upstream_repo=nikitabobko/AeroSpace
tracking_branch=upstream-release
upstream_tag=""
update_tracking_ref=0

usage() {
    cat <<'EOF'
Usage: ./script/sync-upstream-release.sh --upstream-tag vX.Y.Z[-Beta] [options]

Validates that an AeroSpace tag is a published GitHub release and fetches that tag.
Use --update-tracking-ref to advance the pristine upstream-release branch only when
the requested release is a descendant of its current tip. This script never merges
upstream into FlightDeck; resolve that explicit merge on a FlightDeck branch.

Options:
  --upstream-tag TAG         Published AeroSpace release tag (required)
  --upstream-remote REMOTE   Git remote name (default: upstream)
  --upstream-repo OWNER/REPO GitHub repository (default: nikitabobko/AeroSpace)
  --tracking-branch NAME     Pristine local release branch (default: upstream-release)
  --update-tracking-ref      Advance the tracking branch after validation
  -h, --help                 Show this help
EOF
}

while test $# -gt 0; do
    case "$1" in
        --upstream-tag) upstream_tag="$2"; shift 2 ;;
        --upstream-remote) upstream_remote="$2"; shift 2 ;;
        --upstream-repo) upstream_repo="$2"; shift 2 ;;
        --tracking-branch) tracking_branch="$2"; shift 2 ;;
        --update-tracking-ref) update_tracking_ref=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

if test -z "$upstream_tag"; then
    echo "--upstream-tag is mandatory" >&2
    exit 1
fi

is_draft=$(gh release view "$upstream_tag" --repo "$upstream_repo" --json isDraft --jq .isDraft)
if test "$is_draft" != false; then
    echo "$upstream_tag is a draft, not a published upstream release" >&2
    exit 1
fi

git fetch "$upstream_remote" "refs/tags/$upstream_tag:refs/tags/$upstream_tag"
target_commit=$(git rev-parse "$upstream_tag^{}")

if test "$update_tracking_ref" = 1; then
    if git show-ref --verify --quiet "refs/heads/$tracking_branch"; then
        current_commit=$(git rev-parse "$tracking_branch")
        if test "$current_commit" != "$target_commit" && ! git merge-base --is-ancestor "$current_commit" "$target_commit"; then
            echo "$upstream_tag is not a descendant of $tracking_branch; refusing a non-fast-forward update" >&2
            exit 1
        fi
        git branch -f "$tracking_branch" "$target_commit"
    else
        git branch "$tracking_branch" "$target_commit"
    fi
fi

echo "Validated AeroSpace release $upstream_tag at $target_commit"
echo "Merge it explicitly on a FlightDeck branch: git merge --no-ff $upstream_tag"

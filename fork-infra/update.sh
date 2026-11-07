#!/usr/bin/env bash
# Absorb upstream at a release tag: replay exactly our commits onto the newest
# upstream release or preprod tag, push the backup, then build. Never installs.
#
#   fork-infra/update.sh [--tag vX.Y.Z[-preprod.N]] [--releases-only] [--old-base <ref>]
#                        [--no-push] [--no-build] [--version X.Y.Z-qm.N]
#
# Exits at a rebase conflict; resolve it, `git rebase --continue`, then run the
# remaining steps by hand (push, fork-infra/test.sh, fork-infra/build.sh) after
# the patch triage in fork-infra/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW_TAG=""
OLD_BASE=""
RELEASES_ONLY=0
PUSH=1
BUILD=1
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) NEW_TAG="${2:?--tag needs a tag}"; shift 2 ;;
    --releases-only) RELEASES_ONLY=1; shift ;;
    --old-base) OLD_BASE="${2:?--old-base needs a ref}"; shift 2 ;;
    --no-push) PUSH=0; shift ;;
    --no-build) BUILD=0; shift ;;
    --version) BUILD_ARGS+=(--version "${2:?--version needs a value}"); shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "update.sh: $*" >&2; exit 1; }
cd "$ROOT"
[[ "$(git branch --show-current)" == patched ]] || die "check out the patched branch first"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "working tree is dirty"

git fetch --quiet --tags upstream
git fetch --quiet origin
# Tags, not main: they are what upstream ships to testers (preprod) and users.
# The suffix settings sort v0.8.6-preprod.2 below v0.8.6.
if [[ -z "$NEW_TAG" ]]; then
  NEW_TAG="$(git -c versionsort.suffix=-alpha -c versionsort.suffix=-preprod \
    tag --list 'v[0-9]*' --sort=-v:refname \
    | { if [[ "$RELEASES_ONLY" == 1 ]]; then grep -v -- -; else cat; fi; } | awk 'NR == 1')"
fi
[[ -n "$NEW_TAG" ]] || die "no upstream tag found"
git rev-parse --verify --quiet "refs/tags/$NEW_TAG" >/dev/null || die "unknown tag $NEW_TAG"
OLD_BASE="${OLD_BASE:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' patched)}"
NEW_BASE="$(git rev-parse "$NEW_TAG^{commit}")"

if [[ "$(git rev-parse "$OLD_BASE^{commit}")" == "$NEW_BASE" ]]; then
  echo "Already on $NEW_TAG (${NEW_BASE:0:8})."
else
  git merge-base --is-ancestor "$OLD_BASE" "$NEW_BASE" \
    || echo "warning: $NEW_TAG does not descend from $OLD_BASE (a release branch?); replaying anyway" >&2
  echo "Rebasing $(git rev-list --count "$OLD_BASE"..patched) commits from $OLD_BASE onto $NEW_TAG" \
       "($(git rev-list --count "$OLD_BASE".."$NEW_BASE") new upstream commits)."
  # --autosquash folds `fixup! fork-infra:` commits into the one fork-infra commit.
  GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --onto "$NEW_BASE" "$OLD_BASE" patched \
    || die "rebase stopped at a conflict; resolve, continue, then push, test and build by hand"
fi

echo "Our commits on $NEW_TAG:"
git log --reverse --format='  %h %s' "$NEW_BASE"..patched

if [[ "$PUSH" == 1 ]]; then
  git push --force-with-lease origin patched
fi
if [[ "$BUILD" == 1 ]]; then
  "$ROOT/fork-infra/build.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
fi

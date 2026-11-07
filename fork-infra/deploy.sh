#!/usr/bin/env bash
# Deploy the built Muesli zip to one Mac: this one (--local) or another over SSH
# (--remote <host>). Both Macs run the same artifact, installed the same way.
# Order: the other Mac first, this Mac last (fork-infra/README.md, Deploy).
#
#   fork-infra/deploy.sh --remote <ssh-host> [--reset-privacy] [--no-launch]
#   fork-infra/deploy.sh --local [--reset-privacy] [--no-launch]
#
# The artifact is release/Muesli-<fork-infra/VERSION>.zip from build.sh. Before
# anything is copied, it must match its .sha256, carry that version, and be signed
# with our team (Team ID + team designated requirement); anything else would cost
# every privacy grant and raise Keychain prompts on the target. The install itself is
# fork-infra/install.sh on the target (quits Muesli, refuses during a recording,
# backs up the database and config, keeps the replaced app for --rollback).
# On the remote it lives in ~/.local/share/muesli-qm/ with its release/previous/
# rollback copies. Logs: /tmp/muesli-qm-install-*.log on the target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/fork-infra/VERSION")"
ZIP="$ROOT/release/Muesli-$VERSION.zip"
BUNDLE_ID="com.muesli.app"
TEAM_ID="N66437Y9GD"
WANT_DR="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and certificate leaf[subject.OU] = $TEAM_ID"
REMOTE_BASE='.local/share/muesli-qm'   # relative to the remote $HOME; no spaces (scp)
MODE="" HOST="" INSTALL_FLAGS=(--quit) LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) MODE=remote; HOST="${2:?--remote needs an ssh host}"; shift 2 ;;
    --local) MODE=local; shift ;;
    --reset-privacy) INSTALL_FLAGS+=(--reset-privacy); shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MODE" ]] || { sed -n '2,17p' "$0"; exit 2; }
[[ "$LAUNCH" == 1 ]] && INSTALL_FLAGS+=(--launch)

die() { echo "deploy.sh: $*" >&2; exit 1; }
log() { printf '== %s\n' "$*"; }

# 1. Check the artifact locally before it goes anywhere.
[[ -f "$ZIP" && -f "$ZIP.sha256" ]] || die "no $ZIP(.sha256); run fork-infra/build.sh"
(cd "$(dirname "$ZIP")" && shasum -a 256 -c "$(basename "$ZIP").sha256" >/dev/null) || die "$ZIP does not match its .sha256"
SHA="$(cut -d' ' -f1 < "$ZIP.sha256")"
STAGE="$(mktemp -d /tmp/muesli-deploy.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto -x -k "$ZIP" "$STAGE" || die "cannot extract $ZIP"
APP="$STAGE/Muesli.app"
[[ -d "$APP" ]] || die "no Muesli.app in $ZIP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] \
  || die "the zip's app is not version $VERSION"
codesign --verify --deep --strict "$APP" || die "the zip's app does not verify"
[[ "$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM_ID" ]] || die "the zip's app carries no Team ID $TEAM_ID"
[[ "$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" == "$WANT_DR" ]] || die "the zip's app lacks the team designated requirement"
log "artifact Muesli $VERSION, zip sha256 ${SHA:0:16}, team $TEAM_ID"

# The checks every target runs after install; the same text runs locally and remotely.
cat > "$STAGE/postcheck.sh" <<CHECK
app=/Applications/Muesli.app
v="\$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "\$app/Contents/Info.plist")"
[[ "\$v" == "$VERSION" ]] || { echo "POSTCHECK FAILED: installed version \$v"; exit 1; }
codesign --verify --deep --strict "\$app" || { echo "POSTCHECK FAILED: signature"; exit 1; }
[[ "\$(codesign -dvvv "\$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM_ID" ]] || { echo "POSTCHECK FAILED: Team ID"; exit 1; }
if [[ "$LAUNCH" == 1 ]]; then
  sleep 10
  ps -axo comm= | grep '/Muesli.app/Contents/MacOS/Muesli\$' >/dev/null || { echo "POSTCHECK FAILED: Muesli is not running"; exit 1; }
fi
echo "POSTCHECK OK: Muesli \$v, team $TEAM_ID"
CHECK

if [[ "$MODE" == local ]]; then
  "$ROOT/fork-infra/install.sh" --app "$APP" "${INSTALL_FLAGS[@]}"
  bash "$STAGE/postcheck.sh"
  log "DEPLOY OK (local, $VERSION)"
  exit 0
fi

# 2. Remote: stage zip + sha + install.sh, verify the copy there, install, check.
log "staging on $HOST:~/$REMOTE_BASE"
ssh "$HOST" "mkdir -p ~/$REMOTE_BASE/fork-infra ~/$REMOTE_BASE/incoming"
scp -q "$ZIP" "$ZIP.sha256" "$HOST:$REMOTE_BASE/incoming/"
{
  cat <<REMOTE
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
set -euo pipefail
base="\$HOME/$REMOTE_BASE"
cd "\$base/incoming"
shasum -a 256 -c "Muesli-$VERSION.zip.sha256" >/dev/null || { echo "remote copy does not match its sha256"; exit 1; }
rm -rf "\$base/staging"; mkdir -p "\$base/staging"
ditto -x -k "Muesli-$VERSION.zip" "\$base/staging"
chmod +x "\$base/fork-infra/install.sh"
"\$base/fork-infra/install.sh" --app "\$base/staging/Muesli.app" ${INSTALL_FLAGS[*]}
REMOTE
  cat "$STAGE/postcheck.sh"
  cat <<REMOTE
rm -rf "\$base/staging" "\$base/incoming/Muesli-$VERSION.zip" "\$base/incoming/Muesli-$VERSION.zip.sha256"
REMOTE
} > "$STAGE/remote-deploy.sh"
# The script goes over as a file, not stdin: nothing it runs can swallow the rest of it.
scp -q "$ROOT/fork-infra/install.sh" "$HOST:$REMOTE_BASE/fork-infra/install.sh"
scp -q "$STAGE/remote-deploy.sh" "$HOST:$REMOTE_BASE/fork-infra/remote-deploy.sh"
ssh "$HOST" "bash ~/$REMOTE_BASE/fork-infra/remote-deploy.sh"
log "DEPLOY OK ($HOST, $VERSION)"

#!/usr/bin/env bash
# Install our Muesli build into /Applications/Muesli.app, keeping the replaced app
# for rollback. Run it with the operator present: a new signature means macOS
# privacy prompts on first launch (fork-infra/README.md, "Signature costs").
#
#   fork-infra/install.sh [--app <Muesli.app>] [--quit] [--reset-privacy] [--accept-adhoc] [--launch] [--dry-run]
#   fork-infra/install.sh --rollback [--quit] [--reset-privacy] [--launch]
#
#   --app            artifact to install (default release/Muesli.app)
#   --quit           quit a running Muesli first (refused while a meeting is recording)
#   --reset-privacy  tccutil reset All com.muesli.app, so macOS asks again instead of
#                    silently denying grants made for another signature
#   --accept-adhoc   allow an ad-hoc signed build (privacy grants and Keychain access
#                    break again at every rebuild)
#   --rollback       reinstall the most recently replaced app from release/previous/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.muesli.app"
TARGET="/Applications/Muesli.app"
SUPPORT="$HOME/Library/Application Support/Muesli"
PREVIOUS_DIR="$ROOT/release/previous"
APP="$ROOT/release/Muesli.app"
QUIT=0 RESET_PRIVACY=0 ACCEPT_ADHOC=0 ROLLBACK=0 LAUNCH=0 DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?--app needs a path}"; shift 2 ;;
    --quit) QUIT=1; shift ;;
    --reset-privacy) RESET_PRIVACY=1; shift ;;
    --accept-adhoc) ACCEPT_ADHOC=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --launch) LAUNCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/muesli-qm-install-$TS.log"
exec > >(tee -a "$LOG") 2>&1
die() { echo "install.sh: $*" >&2; exit 1; }
run() { if [[ "$DRY_RUN" == 1 ]]; then printf '[dry-run]'; printf ' %q' "$@"; echo; else "$@"; fi; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
signer() { codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | awk 'NR == 1'; }

if [[ "$ROLLBACK" == 1 ]]; then
  APP="$(ls -dt "$PREVIOUS_DIR"/*.app 2>/dev/null | awk 'NR == 1' || true)"
  [[ -n "$APP" ]] || die "nothing to roll back to in $PREVIOUS_DIR"
fi
[[ -d "$APP" ]] || die "no app at $APP (run fork-infra/build.sh first)"
[[ "$(plist "$APP" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "$APP is not $BUNDLE_ID"
codesign --verify --deep --strict "$APP" || die "$APP has an invalid signature"
NEW_VERSION="$(plist "$APP" CFBundleShortVersionString)"
NEW_SIGNER="$(signer "$APP")"
echo "Installing $APP ($NEW_VERSION, signer: ${NEW_SIGNER:-ad-hoc}) -> $TARGET; log $LOG"

if [[ "$ROLLBACK" == 0 ]]; then
  [[ -z "$(plist "$APP" SUFeedURL | tr -d '[:space:]')" ]] \
    || die "$APP has a Sparkle feed; an upstream release would replace it"
  if [[ -z "$NEW_SIGNER" && "$ACCEPT_ADHOC" == 0 ]]; then
    die "ad-hoc signed build: every rebuild loses privacy grants and Keychain access (README, Signature costs). Rebuild with a stable identity, or pass --accept-adhoc."
  fi
fi

# 1. Muesli must not be running. A meeting being recorded is never interrupted.
running() { ps -axo comm= | grep '/Muesli.app/Contents/MacOS/Muesli$' >/dev/null; } # no -q: an early grep exit SIGPIPEs ps under pipefail
if running; then
  [[ "$QUIT" == 1 ]] || die "Muesli is running; quit it, or pass --quit"
  if [[ -f "$SUPPORT/muesli.db" ]]; then
    active="$(sqlite3 -readonly "$SUPPORT/muesli.db" \
      "select count(*) from meetings where meeting_status = 'recording'" 2>/dev/null || echo unknown)"
    [[ "$active" == 0 ]] || die "a meeting is recording (or the check failed: $active); stop it first"
  fi
  run osascript -e "tell application id \"$BUNDLE_ID\" to quit"
  if [[ "$DRY_RUN" == 0 ]]; then
    for _ in $(seq 1 60); do running || break; sleep 1; done
    ! running || die "Muesli did not quit within 60 s"
  fi
fi

# 2. Back up data in place (not cloud-synced). The database uses SQLite's backup API;
#    config.json is copied without its credential fields, which this build moves to Keychain.
if [[ -f "$SUPPORT/muesli.db" ]]; then
  run sqlite3 "$SUPPORT/muesli.db" ".backup '$SUPPORT/muesli.db.pre-$NEW_VERSION-$TS.bak'"
fi
if [[ -f "$SUPPORT/config.json" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry-run] sanitized copy of config.json -> config.json.pre-$NEW_VERSION-$TS.bak"
  else
    jq 'del(.openai_api_key, .anthropic_api_key, .openrouter_api_key, .custom_llm_api_key,
            .custom_llm_api_key_command, .custom_llm_headers)' "$SUPPORT/config.json" \
      > "$SUPPORT/config.json.pre-$NEW_VERSION-$TS.bak"
  fi
fi

# 3. Keep the replaced app for rollback, then install.
if [[ -d "$TARGET" ]]; then
  OLD_VERSION="$(plist "$TARGET" CFBundleShortVersionString)"
  OLD_SIGNER="$(signer "$TARGET")"
  echo "Replacing $OLD_VERSION (signer: ${OLD_SIGNER:-ad-hoc})"
  run mkdir -p "$PREVIOUS_DIR"
  run mv "$TARGET" "$PREVIOUS_DIR/Muesli-$OLD_VERSION-$TS.app"
  run touch "$PREVIOUS_DIR/Muesli-$OLD_VERSION-$TS.app" # --rollback picks the newest
  [[ "$OLD_SIGNER" == "$NEW_SIGNER" ]] || echo "Signer changes: macOS privacy grants and Keychain items made for the old signature will not carry over."
fi
run ditto "$APP" "$TARGET"
run xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
if [[ "$DRY_RUN" == 0 ]]; then
  [[ "$(plist "$TARGET" CFBundleShortVersionString)" == "$NEW_VERSION" ]] || die "installed version mismatch"
  codesign --verify --deep --strict "$TARGET" || die "installed app fails signature verification"
fi

# 4. Privacy grants are keyed to the code signature.
if [[ "$RESET_PRIVACY" == 1 ]]; then
  run tccutil reset All "$BUNDLE_ID"
fi

echo "Installed $NEW_VERSION at $TARGET."
echo "Next: launch it, re-grant microphone, system audio, screen recording, accessibility,"
echo "input monitoring and calendar when asked, then sign in to ChatGPT/Google again if it asks."
if [[ "$LAUNCH" == 1 ]]; then
  run env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin open "$TARGET"
fi

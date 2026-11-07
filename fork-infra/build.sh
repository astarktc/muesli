#!/usr/bin/env bash
# Build our own Muesli (an upstream release tag + our patch commits) into release/.
# Never installs: fork-infra/install.sh does that, with the operator present.
#
#   fork-infra/build.sh [--version X.Y.Z-qm.N] [--identity <SHA-1>] [--swiftpm]
#
# Signs with the operator's Apple Development identity of team N66437Y9GD and pins
# the designated requirement to that team (fork-infra/README.md, Signing identity).
# It fails without that identity: any other signature costs every privacy grant and
# raises a Keychain prompt on install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT/release"
VERSION="$(tr -d '[:space:]' < "$ROOT/fork-infra/VERSION")"
TEAM_ID="N66437Y9GD"   # the operator's Apple personal team (Xcode → Settings → Accounts)
TEAM_REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
IDENTITY_NAME="Apple Development, team $TEAM_ID"
IDENTITY_SHA1=""
USE_XCODE_BUILD=1
BUNDLE_ID="com.muesli.app"
# One SwiftPM cache for builds and tests (fork-infra/test.sh uses it too).
CACHE="$HOME/Library/Caches/muesli-spm/qm-release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --identity) IDENTITY_SHA1="${2:?--identity needs a SHA-1}"; IDENTITY_NAME="(given by --identity)"; shift 2 ;;
    --swiftpm) USE_XCODE_BUILD=0; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "build.sh: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-qm\.[0-9]+$ ]] || die "version '$VERSION' must look like 0.8.6-qm.1"
# The newest valid Apple Development identity whose certificate's OU is our team.
pick_identity() {
  python3 - "$TEAM_ID" <<'PY'
import re, subprocess, sys
team = sys.argv[1]
valid = set(re.findall(r'\b([0-9A-F]{40})\b "Apple Development:',
    subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                   capture_output=True, text=True).stdout))
out = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p", "-c", "Apple Development:"],
                     capture_output=True, text=True).stdout
best = None
for sha, pem in re.findall(r'SHA-1 hash: ([0-9A-F]{40}).*?(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)', out, re.S):
    if sha not in valid:
        continue
    info = subprocess.run(["openssl", "x509", "-noout", "-subject", "-enddate", "-nameopt", "sep_multiline"],
                          input=pem, capture_output=True, text=True).stdout
    if not re.search(r'^\s*OU=' + re.escape(team) + r'\s*$', info, re.M):
        continue
    end = subprocess.run(["date", "-j", "-f", "%b %d %T %Y %Z",
                          re.search(r'notAfter=(.*)', info).group(1).replace("  ", " "), "+%s"],
                         capture_output=True, text=True).stdout.strip() or "0"
    if best is None or int(end) > best[1]:
        best = (sha, int(end))
print(best[0] if best else "")
PY
}
[[ -n "$IDENTITY_SHA1" ]] || IDENTITY_SHA1="$(pick_identity)"
IDENTITY_SHA1="$(tr '[:lower:]' '[:upper:]' <<<"$IDENTITY_SHA1")"
[[ "$IDENTITY_SHA1" =~ ^[0-9A-F]{40}$ ]] || die "no valid Apple Development identity of team $TEAM_ID in this Mac's keychain.
  Do not build without it: any other signature costs every privacy grant and a Keychain prompt per install.
  Create one: Xcode → Settings → Accounts → (Personal Team) → Manage Certificates → + → Apple Development."
security find-identity -v -p codesigning | grep -F "$IDENTITY_SHA1" >/dev/null \
  || die "signing identity $IDENTITY_SHA1 is not a valid codesigning identity in this Mac's keychain"
cd "$ROOT"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "tracked files are modified; commit or stash first (the build must match a commit)"

BASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null)" \
  || die "no upstream release tag below HEAD; patched must sit on an upstream tag"
# Our version must never sort below the upstream release it replaces.
BASE_VERSION="${BASE_TAG#v}"; BASE_VERSION="${BASE_VERSION%%-*}"
[[ "$(printf '%s\n%s\n' "$BASE_VERSION" "${VERSION%%-*}" | sort -V | head -1)" == "$BASE_VERSION" ]] \
  || die "version $VERSION is below its upstream base $BASE_TAG; bump fork-infra/VERSION"

if [[ "$USE_XCODE_BUILD" == 1 ]] && ! command -v xcodegen >/dev/null; then
  die "xcodegen is missing (brew install xcodegen), or pass --swiftpm (no Shortcuts metadata)"
fi
command -v cmake >/dev/null || die "cmake is missing (brew install cmake); the LocalVQE runtime needs it"
xcrun -f metal >/dev/null 2>&1 && xcrun metal -v >/dev/null 2>&1 \
  || die "Metal Toolchain is missing: xcodebuild -downloadComponent MetalToolchain"

mkdir -p "$RELEASE_DIR" "$CACHE"
echo "Building Muesli $VERSION from $(git rev-parse --short HEAD) ($(git branch --show-current)) on $BASE_TAG; signing: $IDENTITY_NAME $IDENTITY_SHA1"

# build_native_app.sh does the real work. Our deltas: install into release/ (not
# /Applications), no Sparkle feed (AppDelegate never starts the updater without
# one), local-only entitlements (no iCloud/APNs: they need a provisioning
# profile), telemetry unconfigured (off), LocalVQE required, our version string,
# and its local signing path (MUESLI_SKIP_SIGN=1 + MUESLI_SIGN_IDENTITY: no
# hardened runtime, as nothing is notarized; the requirement is re-pinned below).
env -u MUESLI_TELEMETRYDECK_APP_ID -u MUESLI_PROVISIONING_PROFILE \
  MUESLI_INSTALL_DIR="$RELEASE_DIR" \
  MUESLI_SPARKLE_FEED_URL="" \
  MUESLI_SPARKLE_EDKEY="" \
  MUESLI_BUILD_VERSION="$VERSION" \
  MUESLI_BUNDLE_ID="$BUNDLE_ID" \
  MUESLI_SKIP_SIGN=1 \
  MUESLI_SIGN_IDENTITY="$IDENTITY_SHA1" \
  MUESLI_ENTITLEMENTS="$ROOT/scripts/MuesliLocalOnly.entitlements" \
  MUESLI_APS_ENVIRONMENT="" \
  MUESLI_TELEMETRY_CHANNEL=unconfigured \
  MUESLI_USE_XCODE_BUILD="$USE_XCODE_BUILD" \
  MUESLI_BUILD_LOCALVQE=1 \
  MUESLI_REQUIRE_LOCALVQE=1 \
  MUESLI_SWIFTPM_SCRATCH_PATH="$CACHE/swiftpm" \
  MUESLI_XCODEBUILD_DERIVED_DATA="$CACHE/xcodebuild" \
  "$ROOT/scripts/build_native_app.sh" release

APP="$RELEASE_DIR/Muesli.app"
PLIST="$APP/Contents/Info.plist"
[[ -d "$APP" ]] || die "build reported success but $APP is missing"

# Pin the designated requirement to our TEAM, not to one certificate: privacy (TCC)
# grants and Keychain ACLs record it, and Muesli's credentials are legacy Keychain
# items whose partition list admits code by Team ID, so a rebuild or a renewed
# certificate of the same team keeps every grant. Inner code first, the app last.
repin() {
  codesign --force --sign "$IDENTITY_SHA1" --timestamp=none --preserve-metadata=entitlements,flags \
    -r="designated => identifier \"$2\" and $TEAM_REQ" "$1" 2>&1 | grep -v ': replacing existing signature$' || true
}
COTYPIST="$APP/Contents/Library/Input Methods/MuesliCotypist.app"
if [[ -d "$COTYPIST" ]]; then
  repin "$COTYPIST" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$COTYPIST/Contents/Info.plist")"
fi
repin "$APP/Contents/MacOS/muesli-cli" "muesli-cli"
repin "$APP" "$BUNDLE_ID"

# Verify the properties our install relies on.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "bundle id is $(plist CFBundleIdentifier)"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "version is $(plist CFBundleShortVersionString)"
[[ -z "$(plist SUFeedURL | tr -d '[:space:]')" ]] || die "SUFeedURL is set; auto-update would replace this build"
[[ -z "$(plist MuesliTelemetryDeckAppID | tr -d '[:space:]')" ]] || die "telemetry is configured"
codesign --verify --deep --strict "$APP" || die "signature does not verify"
source "$ROOT/scripts/localvqe_runtime.sh"
muesli_localvqe_runtime_is_complete "$APP/Contents/MacOS" || die "LocalVQE runtime is incomplete in the bundle"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep "icloud" >/dev/null; then
  die "iCloud entitlements are present; this build has no provisioning profile"
fi

# The app, muesli-cli and Cotypist must carry our Team ID and the team requirement,
# never a cdhash or a certificate pin that changes per build or per renewal.
[[ "$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM_ID" ]] \
  || die "the signature carries no Team ID $TEAM_ID"
designated() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
TEAM_DR_TAIL="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and certificate leaf[subject.OU] = $TEAM_ID"
DR="$(designated "$APP")"
[[ "$DR" == "identifier \"$BUNDLE_ID\" and $TEAM_DR_TAIL" ]] || die "unexpected designated requirement: ${DR:-none}"
for inner in "$APP/Contents/MacOS/muesli-cli" "$COTYPIST"; do
  [[ -e "$inner" ]] || continue
  [[ "$(designated "$inner")" == *" and $TEAM_DR_TAIL" ]] || die "$(basename "$inner") does not carry the team requirement"
done

ZIP="$RELEASE_DIR/Muesli-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

SIGNATURE="$(codesign -dvvv "$APP" 2>&1)"
{
  echo "version: $VERSION"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(scutil --get LocalHostName 2>/dev/null || hostname)"
  echo "commit: $(git rev-parse HEAD) ($(git branch --show-current))"
  echo "upstream base: $BASE_TAG ($(git rev-parse "$BASE_TAG^{commit}"))"
  echo "patches:"
  git log --reverse --format='  %h %s' "$BASE_TAG..HEAD"
  echo "signing identity: $IDENTITY_NAME, SHA-1 $IDENTITY_SHA1"
  echo "designated requirement: $DR"
  grep -E '^(Authority|TeamIdentifier|CDHash)=' <<<"$SIGNATURE" | sed 's/^/  /'
  echo "zip: $(cat "$ZIP.sha256")"
} > "$RELEASE_DIR/BUILD-INFO.txt"

cat "$RELEASE_DIR/BUILD-INFO.txt"
echo "Built $APP and $ZIP. Deploy to both Macs: fork-infra/deploy.sh --remote mac-uni-auto, then --local (README, Deploy)."

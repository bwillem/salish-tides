#!/usr/bin/env bash
#
# Archive Salish Tides and upload it to App Store Connect for distribution, using
# an App Store Connect API key (no Apple-ID password, no interactive Organizer).
#
# This is the build-toolchain half of the release flow; the version bump and
# release notes are handled by dev/release/release.py. Typical order for a release:
#
#     python3 dev/release/release.py apply --version X.Y.Z   # bump the version
#     # (commit) ...
#     dev/release/distribute.sh                              # archive + upload
#
# Credentials come from Config/Secrets.xcconfig (gitignored), overridable by env:
#     ASC_KEY_ID       key id (also the AuthKey_<id>.p8 filename)
#     ASC_ISSUER_ID    issuer UUID
#     ASC_KEY_PATH     absolute path to the .p8 (kept OUTSIDE the repo)
#     DEVELOPMENT_TEAM 10-char Apple Team ID
# The .p8 private key is never read by this script directly — it's handed to
# xcodebuild/altool by path/id. altool also auto-discovers it in the directory of
# ASC_KEY_PATH (exported as API_PRIVATE_KEYS_DIR below).
#
# Usage:
#     dev/release/distribute.sh [options]
#       --skip-archive        reuse the archive at --archive instead of building
#       --archive PATH        archive path (default: build/dist/SalishTides.xcarchive)
#       --archive-only        stop after archiving (no export/upload)
#       --validate-only       validate the .ipa against App Store Connect, don't upload
#       -h, --help
#
# Nothing is uploaded until the archive + export succeed; upload is the last step.

set -euo pipefail

SCHEME="SalishTides"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$REPO_ROOT/Config/Secrets.xcconfig"

ARCHIVE_PATH="$REPO_ROOT/build/dist/SalishTides.xcarchive"
EXPORT_DIR="$REPO_ROOT/build/dist/export"
SKIP_ARCHIVE=0
ARCHIVE_ONLY=0
VALIDATE_ONLY=0

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-archive)  SKIP_ARCHIVE=1; shift ;;
    --archive)       ARCHIVE_PATH="$2"; shift 2 ;;
    --archive-only)  ARCHIVE_ONLY=1; shift ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

# --- config: env wins, else read "KEY = value" from an xcconfig --------------- #
# The trailing `|| true` is load-bearing: without it a grep miss returns non-zero,
# which under `set -euo pipefail` aborts the whole script at the assignment (before
# any preflight `die` can report the real problem). A miss must yield "" instead.
read_xcconfig() {  # read_xcconfig <key> <file>
  [[ -f "$2" ]] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" | tail -1 \
    | sed -E "s/^[^=]*=[[:space:]]*//; s/[[:space:]]*(\/\/.*)?$//" || true
}
read_cfg() { read_xcconfig "$1" "$SECRETS"; }
read_base() { read_xcconfig "$1" "$REPO_ROOT/Config/Base.xcconfig"; }

ASC_KEY_ID="${ASC_KEY_ID:-$(read_cfg ASC_KEY_ID)}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(read_cfg ASC_ISSUER_ID)}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$(read_cfg ASC_KEY_PATH)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(read_cfg DEVELOPMENT_TEAM)}"

# --- preflight: fail loudly BEFORE doing any expensive/irreversible work ------ #
[[ -n "$ASC_KEY_ID" ]]      || die "ASC_KEY_ID not set (Config/Secrets.xcconfig or env)"
[[ -n "$ASC_ISSUER_ID" ]]   || die "ASC_ISSUER_ID not set (Config/Secrets.xcconfig or env)"
[[ -n "$ASC_KEY_PATH" ]]    || die "ASC_KEY_PATH not set (Config/Secrets.xcconfig or env)"
[[ -n "$DEVELOPMENT_TEAM" ]]|| die "DEVELOPMENT_TEAM not set (Config/Secrets.xcconfig or env)"
[[ -f "$ASC_KEY_PATH" ]]    || die "API key file not found at ASC_KEY_PATH: $ASC_KEY_PATH"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode command line tools)"
# The upload/validate steps need altool; check it up front rather than after a
# multi-minute archive + export (unless we're only archiving).
if [[ "$ARCHIVE_ONLY" -eq 0 ]]; then
  command -v xcrun >/dev/null || die "xcrun not found (install Xcode command line tools)"
  xcrun --find altool >/dev/null 2>&1 || die "altool not found (needed to upload; try: xcrun --find altool)"
fi

# altool discovers AuthKey_<id>.p8 in these dirs; point it at wherever the key lives.
export API_PRIVATE_KEYS_DIR
API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)"

# Version + build live in Base.xcconfig (never Secrets), so read them from there.
MARKETING_VERSION="$(read_base MARKETING_VERSION)"
BUILD_NUMBER="$(read_base CURRENT_PROJECT_VERSION)"

echo "── Salish Tides · App Store Connect distribution ─────────────────────────"
echo "  version    $MARKETING_VERSION ($BUILD_NUMBER)"
echo "  team       $DEVELOPMENT_TEAM"
echo "  key id     $ASC_KEY_ID   issuer ${ASC_ISSUER_ID:0:8}…"
echo "  archive    $ARCHIVE_PATH"
echo "──────────────────────────────────────────────────────────────────────────"

auth_flags=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# --- 1. archive -------------------------------------------------------------- #
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
  echo "▸ archiving (Release, generic/iOS)…"
  rm -rf "$ARCHIVE_PATH"
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
  xcodebuild archive \
    -project "$REPO_ROOT/SalishTides.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${auth_flags[@]}"
else
  [[ -d "$ARCHIVE_PATH" ]] || die "--skip-archive but no archive at $ARCHIVE_PATH"
  echo "▸ reusing existing archive"
fi

if [[ "$ARCHIVE_ONLY" -eq 1 ]]; then
  echo "✓ archive ready at $ARCHIVE_PATH (--archive-only)"
  exit 0
fi

# --- 2. export a signed .ipa ------------------------------------------------- #
echo "▸ exporting signed .ipa…"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# Xcode 16 renamed the App Store export method 'app-store' → 'app-store-connect'
# (the old value is rejected on newer toolchains); pick by major version.
XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | sed -nE '1s/^Xcode ([0-9]+).*/\1/p')"
if [[ -n "$XCODE_MAJOR" && "$XCODE_MAJOR" -ge 16 ]]; then
  EXPORT_METHOD="app-store-connect"
else
  EXPORT_METHOD="app-store"
fi

PLIST="$EXPORT_DIR/ExportOptions.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST_EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PLIST" \
  "${auth_flags[@]}"

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[[ -n "$IPA" ]] || die "export produced no .ipa in $EXPORT_DIR"
echo "  exported: $IPA"

# --- 3. validate / upload ---------------------------------------------------- #
altool_creds=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")

echo "▸ validating with App Store Connect…"
xcrun altool --validate-app -f "$IPA" -t ios "${altool_creds[@]}"

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  echo "✓ validation passed (--validate-only); not uploaded"
  exit 0
fi

echo "▸ uploading to App Store Connect…"
xcrun altool --upload-app -f "$IPA" -t ios "${altool_creds[@]}"

echo "✓ uploaded $MARKETING_VERSION ($BUILD_NUMBER). It'll appear under TestFlight"
echo "  once processing finishes; attach it to the version and Submit for Review."

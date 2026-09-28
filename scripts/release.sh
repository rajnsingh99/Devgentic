#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2025-2026 Raj Singh
#
# release.sh — build a signed, notarized, Sparkle-ready Devgentic.dmg. Maintainer-only.
#
#   scripts/release.sh <version> [--notes <release-notes.html>] [--allow-dirty]
#
#   e.g. scripts/release.sh 0.9.0 --notes docs/release-notes/0.9.0.html
#
# Pipeline: archive → export (Developer ID) → signing gate → notarize + staple the app → DMG →
# sign + notarize + staple the DMG → EdDSA-sign it into appcast.xml → checksum.
#
# ⚠️ IT STOPS BEFORE ANYTHING PUBLIC. Uploading the DMG and publishing appcast.xml are printed as
# next steps for a human. Publishing the appcast is what makes every installed copy offer the
# update, and it cannot be taken back from anyone who already installed it.
#
# Needs, all on THIS machine:
#   - "Developer ID Application" certificate for team FM3V43ST5B (login Keychain)
#   - notarytool Keychain profile `devgentic-notary`   (xcrun notarytool store-credentials …)
#   - Sparkle EdDSA private key (login Keychain, generate_keys default account)
#   - create-dmg                                       (brew install create-dmg)
#
# State kept between releases, in build/release/ (gitignored):
#   appcast.xml   — the MASTER copy. Each release adds one item to it. If it is missing, the
#                   published one is downloaded so earlier releases are never dropped.

set -euo pipefail

TEAM_ID="FM3V43ST5B"
NOTARY_PROFILE="devgentic-notary"
REPO="rajnsingh99/devgentic"
FEED_URL="https://rajnsingh99.github.io/devgentic/appcast.xml"
SITE_URL="https://rajnsingh99.github.io/devgentic/"
# The asset name is FIXED: the website links to …/releases/latest/download/Devgentic.dmg, and the
# appcast item points at the immutable tagged URL …/download/v<version>/Devgentic.dmg (Sparkle's
# EdDSA signature is per-file, so it must never point at a moving target).
DMG_NAME="Devgentic.dmg"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

# ------------------------------------------------------------------------------------- arguments
VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: scripts/release.sh <version> [--notes <file.html>] [--allow-dirty]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be MAJOR.MINOR.PATCH, got '$VERSION'"
shift
NOTES=""
ALLOW_DIRTY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="${2:-}"; [[ -f "$NOTES" ]] || die "release notes not found: $NOTES"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

RELEASE_ROOT="$PROJECT_DIR/build/release"
WORK="$RELEASE_ROOT/$VERSION"
MASTER_APPCAST="$RELEASE_ROOT/appcast.xml"
SPARKLE_BIN="$PROJECT_DIR/.derivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

# ---------------------------------------------------------------------------------- preflight
step "Preflight"

if [[ -n "$(git status --porcelain)" ]]; then
  if (( ALLOW_DIRTY )); then
    printf '  \033[33m!\033[0m worktree is dirty — the release will NOT match any commit (--allow-dirty)\n'
  else
    die "worktree is dirty. Commit first so the release is reproducible from a tag, or pass --allow-dirty for a rehearsal."
  fi
else
  ok "worktree clean at $(git rev-parse --short HEAD)"
fi

IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" | head -1)"
[[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' certificate for team $TEAM_ID in the Keychain"
ok "$IDENTITY"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing or invalid — run: xcrun notarytool store-credentials $NOTARY_PROFILE --key … --key-id … --issuer …"
ok "notarytool profile '$NOTARY_PROFILE'"

command -v create-dmg >/dev/null || die "create-dmg not installed — brew install create-dmg"
ok "create-dmg $(create-dmg --version | awk '{print $2}')"

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  xcodebuild -resolvePackageDependencies -project Devgentic.xcodeproj -scheme devgentic \
    -derivedDataPath .derivedData >/dev/null
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "Sparkle tools not found at $SPARKLE_BIN"
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 || die "no Sparkle EdDSA private key in the login Keychain — restore it: generate_keys -f <backup>"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Devgentic/Info.plist)"
[[ "$("$SPARKLE_BIN/generate_keys" -p)" == "$PLIST_KEY" ]] \
  || die "the Keychain's Sparkle key does not match SUPublicEDKey in Info.plist — every installed copy would REJECT this update"
ok "Sparkle key matches SUPublicEDKey"

# ------------------------------------------------------------------------ previous appcast
mkdir -p "$RELEASE_ROOT"
if [[ ! -f "$MASTER_APPCAST" ]]; then
  HTTP="$(curl -sS -o "$MASTER_APPCAST.download" -w '%{http_code}' "$FEED_URL" || true)"
  if [[ "$HTTP" == "200" ]]; then
    mv "$MASTER_APPCAST.download" "$MASTER_APPCAST"
    ok "no local appcast — downloaded the published one"
  else
    rm -f "$MASTER_APPCAST.download"
    ok "no appcast published yet (HTTP $HTTP) — this is the first release"
  fi
fi

item_count() { if [[ -f "$1" ]]; then grep -c '<item>' "$1" || true; else echo 0; fi; }
PREV_ITEMS="$(item_count "$MASTER_APPCAST")"
PREV_MAX_BUILD="$( { [[ -f "$MASTER_APPCAST" ]] && grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$MASTER_APPCAST" \
  | grep -o '[0-9]*'; echo 0; } | sort -n | tail -1)"
if [[ -f "$MASTER_APPCAST" ]] && grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$MASTER_APPCAST"; then
  die "version $VERSION is already in the appcast — pick a new version"
fi

# --------------------------------------------------------------------------------- build number
# YYYYMMDDNN, strictly greater than every build already in the appcast. Sparkle compares THIS, not
# the marketing version: a release that reuses or lowers it is never offered to anyone.
TODAY="$(date +%Y%m%d)"
BUILD="${TODAY}01"
if (( PREV_MAX_BUILD >= BUILD )); then BUILD=$((PREV_MAX_BUILD + 1)); fi
[[ "${BUILD:0:8}" == "$TODAY" ]] || die "build number $BUILD overflowed today's 99-release sequence"
ok "version $VERSION, build $BUILD (previous highest: $PREV_MAX_BUILD)"

rm -rf "$WORK"
mkdir -p "$WORK"

# ------------------------------------------------------------------------------ archive + export
step "Archive"
xcodebuild -project Devgentic.xcodeproj -scheme devgentic -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .derivedData \
  -archivePath "$WORK/Devgentic.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive > "$WORK/archive.log" 2>&1 || die "archive failed — see $WORK/archive.log"
ok "archived"

step "Export (Developer ID)"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>export</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$WORK/Devgentic.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" > "$WORK/export.log" 2>&1 \
  || die "export failed — see $WORK/export.log"
# The target is `devgentic`, so the product is devgentic.app. Users see the folder name in
# /Applications; the bundle directory name is not part of the code signature.
APP="$WORK/Devgentic.app"
mv "$WORK/export/devgentic.app" "$APP"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" && "$BUILT_BUILD" == "$BUILD" ]] \
  || die "the built app says $BUILT_VERSION ($BUILT_BUILD), expected $VERSION ($BUILD)"
ok "exported $VERSION ($BUILD)"

step "Signing gate"
scripts/verify-release-signing.sh "$APP" > "$WORK/gate.log" 2>&1 || { cat "$WORK/gate.log"; die "signing gate failed"; }
ok "passed"

# ----------------------------------------------------------------------------------- notarize
# Returns only on Accepted; otherwise prints Apple's log and exits.
notarize() {
  local file="$1" label="$2" out id status
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>&1)" || true
  id="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  status="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    printf '%s\n' "$out"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "$label notarization: ${status:-submission failed}"
  fi
  ok "$label notarized ($id)"
}

step "Notarize the app (usually a few minutes; the first ever took ~40)"
ditto -c -k --keepParent "$APP" "$WORK/Devgentic-app.zip"
notarize "$WORK/Devgentic-app.zip" "app"
xcrun stapler staple "$APP" >/dev/null && xcrun stapler validate "$APP" >/dev/null || die "stapling the app failed"
ok "app stapled"

# ------------------------------------------------------------------------------------------ DMG
step "DMG"
DMG_SRC="$WORK/dmg-src"
mkdir -p "$DMG_SRC"
ditto "$APP" "$DMG_SRC/Devgentic.app"
DMG="$WORK/$DMG_NAME"
# ⚠️ The window layout is applied by AppleScript driving FINDER, which needs Automation permission
# for whatever runs this script (Terminal, iTerm, an agent). Unanswered, it times out (-1712). The
# fallback skips that step: the DMG is equally valid, its window just uses Finder's default layout.
DMG_LAYOUT=(--window-size 540 380 --icon-size 128 --icon "Devgentic.app" 140 180
            --hide-extension "Devgentic.app" --app-drop-link 400 180)
if ! create-dmg --volname "Devgentic $VERSION" "${DMG_LAYOUT[@]}" \
     "$DMG" "$DMG_SRC" > "$WORK/dmg.log" 2>&1; then
  printf '  \033[33m!\033[0m styled layout failed (Finder automation?) — building without it; see %s\n' "$WORK/dmg.log"
  rm -f "$DMG" "$WORK"/rw.*.dmg
  create-dmg --volname "Devgentic $VERSION" --skip-jenkins --app-drop-link 400 180 \
    "$DMG" "$DMG_SRC" >> "$WORK/dmg.log" 2>&1 || die "create-dmg failed — see $WORK/dmg.log"
fi
codesign --sign "$IDENTITY" --timestamp "$DMG" || die "signing the DMG failed"
ok "DMG built and signed"

step "Notarize the DMG"
notarize "$DMG" "DMG"
xcrun stapler staple "$DMG" >/dev/null && xcrun stapler validate "$DMG" >/dev/null || die "stapling the DMG failed"
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || die "Gatekeeper rejects the DMG"
ok "DMG stapled; Gatekeeper accepts it"

# -------------------------------------------------------------------------------------- appcast
# ⚠️ generate_appcast runs over a folder holding ONLY this release's DMG plus the previous appcast,
# so the download prefix (which carries v<version>/) applies to the new item alone and every
# earlier item is left exactly as published. The item-count check below enforces that.
# No delta updates: they would need every previous DMG in the folder under distinct names.
step "Appcast"
FEED_DIR="$WORK/appcast"
mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/$DMG_NAME"
[[ -f "$MASTER_APPCAST" ]] && cp "$MASTER_APPCAST" "$FEED_DIR/appcast.xml"
NOTES_ARGS=()
if [[ -n "$NOTES" ]]; then
  cp "$NOTES" "$FEED_DIR/${DMG_NAME%.dmg}.html"
  NOTES_ARGS=(--embed-release-notes)
fi
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "$SITE_URL" \
  ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"} \
  "$FEED_DIR" > "$WORK/appcast.log" 2>&1 || die "generate_appcast failed — see $WORK/appcast.log"

NEW_APPCAST="$FEED_DIR/appcast.xml"
NEW_ITEMS="$(item_count "$NEW_APPCAST")"
(( NEW_ITEMS == PREV_ITEMS + 1 )) \
  || die "appcast has $NEW_ITEMS item(s), expected $((PREV_ITEMS + 1)) — an earlier release would be dropped or duplicated. Nothing was published."
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$NEW_APPCAST" || die "the new item does not carry build $BUILD"
grep -q "releases/download/v$VERSION/$DMG_NAME" "$NEW_APPCAST" || die "the new item does not point at the tagged download URL"
grep -q 'sparkle:edSignature=' "$NEW_APPCAST" || die "the new item has no EdDSA signature — every installed copy would refuse it"
cp "$NEW_APPCAST" "$WORK/appcast.xml"
ok "appcast: $PREV_ITEMS → $NEW_ITEMS item(s), new item signed"

# ------------------------------------------------------------------------------------- summary
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(du -h "$DMG" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$DMG_NAME" > "$WORK/$DMG_NAME.sha256"

cat <<EOF

$(printf '\033[32m✓ Devgentic %s (%s) is ready.\033[0m' "$VERSION" "$BUILD")

  DMG       $DMG  ($SIZE)
  SHA-256   $SHA
  Appcast   $WORK/appcast.xml

Nothing has been published. To release — in this order:

  1. Tag and push:
       git tag -a v$VERSION -m "Devgentic $VERSION" && git push origin v$VERSION

  2. Create the GitHub Release with the DMG (asset name must stay $DMG_NAME):
       gh release create v$VERSION "$DMG" "$WORK/$DMG_NAME.sha256" --repo $REPO --title "Devgentic $VERSION" --notes-file <notes.md>

  3. Download it back and check it (proves the upload is the file that was signed):
       curl -L -o /tmp/check.dmg https://github.com/$REPO/releases/download/v$VERSION/$DMG_NAME && shasum -a 256 /tmp/check.dmg

  4. ⚠️ LAST, and only after 3 matches: publish the appcast. This is the step that makes every
     installed copy offer the update.
       copy $WORK/appcast.xml to the Pages site as appcast.xml, then:
       cp "$WORK/appcast.xml" "$MASTER_APPCAST"
EOF

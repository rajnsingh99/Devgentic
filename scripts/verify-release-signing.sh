#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2025-2026 Raj Singh
#
# verify-release-signing.sh — the KC-7 release gate.
#
# ⚠️ WHY THIS EXISTS. The Release configuration shipped with
# `"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-"` — ad-hoc — identical to Debug. Every secret the app owns
# lives in the LEGACY FILE-BASED login keychain, whose per-item ACL is pinned to the code identity
# that created the item. An ad-hoc signature has no stable designated requirement: its cdhash changes
# with every build, so every Sparkle update presents as a DIFFERENT application to items the previous
# build created. The user is then prompted per item, and a denial returns `errSecAuthFailed` — which
# is precisely the input that four of the audit's P1 rows mishandle by deleting or forgetting the
# credential — an ACL denial must be treated as "cannot read right now", never as "the item is gone".
#
# A Developer ID signature's designated requirement is anchored on the stable Team ID, so it survives
# re-signing. That is the whole fix, and this script is what stops it silently regressing.
#
# Usage:
#   scripts/verify-release-signing.sh                 # check the build CONFIGURATION only
#   scripts/verify-release-signing.sh path/to/App.app # also check a BUILT app's real signature
#
# Exit 0 = pass. Non-zero = the release must not ship.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$PROJECT_DIR/Devgentic.xcodeproj/project.pbxproj"
APP_PATH="${1:-}"
FAILURES=0
# The Developer ID team every release is signed by. Changing it orphans every Keychain item and TCC
# grant an installed copy holds, so it is pinned here rather than read back from the project.
EXPECTED_TEAM_ID="FM3V43ST5B"

fail() { printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  \033[32m✓ ok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33m! warn\033[0m  %s\n' "$1"; }

echo "── Release signing gate ─────────────────────────────────────────"

if [[ ! -f "$PBXPROJ" ]]; then
  fail "project.pbxproj not found at $PBXPROJ"
  exit 1
fi

# ---------------------------------------------------------------- configuration
# Extract the app target's Release buildSettings block. Bounded by the enclosing
# `/* Release */ = {` ... `name = Release;` pair that also carries PRODUCT_BUNDLE_IDENTIFIER for the
# app (the test/uitest targets have their own Release blocks and are deliberately not checked —
# only the shipped app's signature binds keychain ACLs).
release_block() {
  awk '
    /\/\* Release \*\/ = \{/ { inblock = 1; buf = ""; }
    inblock { buf = buf $0 "\n" }
    /name = Release;/ {
      if (inblock && buf ~ /PRODUCT_BUNDLE_IDENTIFIER = app\.devgentic\.macos;/) print buf
      inblock = 0
    }
  ' "$PBXPROJ"
}

BLOCK="$(release_block)"

if [[ -z "$BLOCK" ]]; then
  fail "could not locate the app target's Release build configuration (bundle id app.devgentic.macos)"
  echo
  echo "$FAILURES failure(s)."
  exit 1
fi

# 1. Not ad-hoc.
IDENTITY="$(printf '%s' "$BLOCK" | sed -n 's/.*CODE_SIGN_IDENTITY\[sdk=macosx\*\]" = \(.*\);/\1/p' | tr -d '"' | head -1)"
if [[ -z "$IDENTITY" ]]; then
  fail "Release sets no CODE_SIGN_IDENTITY[sdk=macosx*] — it will inherit, and may be ad-hoc"
elif [[ "$IDENTITY" == "-" ]]; then
  fail "Release CODE_SIGN_IDENTITY is \"-\" (AD-HOC). Keychain ACLs will break on every Sparkle update."
elif [[ "$IDENTITY" == *'$('* ]]; then
  # Overridable variable — resolve its default from the same block.
  VAR="$(printf '%s' "$IDENTITY" | sed -n 's/.*\$(\([A-Z_][A-Z0-9_]*\)).*/\1/p')"
  DEFAULT="$(printf '%s' "$BLOCK" | sed -n "s/.*${VAR} = \(.*\);/\1/p" | tr -d '"' | head -1)"
  if [[ "$DEFAULT" == "-" || -z "$DEFAULT" ]]; then
    fail "Release identity resolves to \$($VAR) whose default is \"${DEFAULT:-<unset>}\" — ad-hoc by default"
  elif [[ "$DEFAULT" == "Developer ID Application"* ]]; then
    pass "Release CODE_SIGN_IDENTITY defaults to '$DEFAULT' (overridable via $VAR)"
  else
    warn "Release identity defaults to '$DEFAULT' — expected 'Developer ID Application'"
  fi
elif [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  pass "Release CODE_SIGN_IDENTITY is '$IDENTITY'"
else
  warn "Release CODE_SIGN_IDENTITY is '$IDENTITY' — expected 'Developer ID Application' for notarized distribution"
fi

# 1b. Manual signing style. Xcode refuses a manually specified "Developer ID Application" identity
# under CODE_SIGN_STYLE = Automatic ("conflicting provisioning settings") — the build fails before
# compiling anything, so this is caught here rather than at release time.
if printf '%s' "$BLOCK" | grep -q 'CODE_SIGN_STYLE = Manual;'; then
  pass "CODE_SIGN_STYLE = Manual"
else
  fail "Release CODE_SIGN_STYLE is not Manual — Xcode rejects a Developer ID identity under Automatic signing"
fi

# 1c. Team ID. The designated requirement is anchored on it — it is the stable identity the Keychain
# ACLs bind to, so it must never change across releases.
TEAM="$(printf '%s' "$BLOCK" | sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);/\1/p' | head -1)"
if [[ "$TEAM" == "$EXPECTED_TEAM_ID" ]]; then
  pass "DEVELOPMENT_TEAM = $TEAM"
elif [[ -z "$TEAM" ]]; then
  fail "Release sets no DEVELOPMENT_TEAM"
else
  fail "Release DEVELOPMENT_TEAM is $TEAM, expected $EXPECTED_TEAM_ID — a different team is a different application to every existing Keychain item"
fi

# 1d. No injected get-task-allow. `xcodebuild build` adds it to EVERY configuration unless this is
# off — only archive/export strips it — so a Release product built the ordinary way was not
# notarizable and let any local process attach to the app holding decrypted Keychain secrets.
if printf '%s' "$BLOCK" | grep -q 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;'; then
  pass "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO"
else
  fail "Release does not set CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO — a plain build embeds get-task-allow"
fi

# 2. Hardened runtime — required for notarization.
if printf '%s' "$BLOCK" | grep -q 'ENABLE_HARDENED_RUNTIME = YES;'; then
  pass "ENABLE_HARDENED_RUNTIME = YES"
else
  fail "Release does not set ENABLE_HARDENED_RUNTIME = YES — the build cannot be notarized"
fi

# 2b. Apple silicon only. Without ARCHS the Release build is universal: the x86_64 slice is about
# half the download and nothing guards MLX on Intel. Set at PROJECT level so every target and
# package inherits it; every ARCHS line in the project must say arm64.
ARCHS_LINES="$(grep -E '^[[:space:]]*ARCHS = ' "$PBXPROJ")"
if [[ -z "$ARCHS_LINES" ]]; then
  fail "the project sets no ARCHS — Release builds a universal (x86_64 + arm64) binary"
elif printf '%s\n' "$ARCHS_LINES" | grep -qv 'ARCHS = arm64;'; then
  fail "an ARCHS setting other than arm64: $(printf '%s\n' "$ARCHS_LINES" | grep -v 'ARCHS = arm64;' | head -1 | xargs)"
else
  pass "ARCHS = arm64 (Apple silicon only)"
fi

# 3. Secure timestamp — notarization rejects signatures without one.
if printf '%s' "$BLOCK" | grep -q 'OTHER_CODE_SIGN_FLAGS.*--timestamp'; then
  pass "OTHER_CODE_SIGN_FLAGS carries --timestamp"
else
  warn "no --timestamp in OTHER_CODE_SIGN_FLAGS — notarization requires a secure timestamp"
fi

# 4. Entitlements file is actually wired up.
if printf '%s' "$BLOCK" | grep -q 'CODE_SIGN_ENTITLEMENTS'; then
  pass "CODE_SIGN_ENTITLEMENTS is set"
else
  fail "Release sets no CODE_SIGN_ENTITLEMENTS — the microphone entitlement will not be applied"
fi

# ------------------------------------------------------- entitlements & TCC strings
# ⚠️ These two checks exist because the signature can be perfect while the app is still broken.
# An entitlement grants the RIGHT to ask; the Info.plist usage string is what TCC shows the user,
# and calling a protected API without its string TERMINATES the process. Both are invisible in a
# Debug build (ad-hoc, no hardened runtime), so neither failure ever reproduces in development.
ENTITLEMENTS_FILE="$PROJECT_DIR/Devgentic/Devgentic.entitlements"
INFO_PLIST="$PROJECT_DIR/Devgentic/Info.plist"

echo
echo "── Hardened-runtime entitlements ────────────────────────────────"
if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  fail "entitlements file not found at $ENTITLEMENTS_FILE"
else
  for key in \
    com.apple.security.device.audio-input \
    com.apple.security.automation.apple-events \
    com.apple.security.personal-information.calendars \
    com.apple.security.personal-information.addressbook
  do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
      pass "$key"
    else
      fail "$key is MISSING — the feature it covers dies silently in the hardened build"
    fi
  done

  # The inverse check. Every com.apple.security.cs.* opt-out was audited and rejected; one
  # reappearing means somebody silenced a crash with a process-wide weakening instead of fixing it.
  # ⚠️ PARSE the plist, never grep the raw file — the header comment names these keys in order to
  # forbid them, and a text grep reports that prose as a live entitlement.
  CS_KEYS="$(plutil -convert json -o - "$ENTITLEMENTS_FILE" 2>/dev/null \
    | tr ',{}' '\n\n\n' | sed -n 's/.*"\(com\.apple\.security\.cs\.[a-z-]*\)".*/\1/p' \
    | sort -u | tr '\n' ' ')"
  if [[ -n "${CS_KEYS// /}" ]]; then
    warn "hardened-runtime OPT-OUT present: $CS_KEYS — each weakens the runtime process-wide and draws notarization scrutiny. Justify it in the file or remove it."
  else
    pass "no com.apple.security.cs.* opt-outs (none are needed — see the file's header)"
  fi
fi

echo
echo "── TCC usage descriptions ───────────────────────────────────────"
if [[ ! -f "$INFO_PLIST" ]]; then
  fail "Info.plist not found at $INFO_PLIST"
else
  for key in \
    NSMicrophoneUsageDescription \
    NSAppleEventsUsageDescription \
    NSCalendarsFullAccessUsageDescription \
    NSRemindersFullAccessUsageDescription \
    NSContactsUsageDescription
  do
    VALUE="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null)"
    if [[ -n "$VALUE" ]]; then
      pass "$key"
    else
      fail "$key is MISSING — calling its API TERMINATES the app (not an error the tool can report)"
    fi
  done
fi

# ------------------------------------------------------------------------ Sparkle
# ⚠️ Both values are compiled into every shipped binary and can never be changed for copies already
# installed: a different key makes them reject every future update; a different feed host strands
# them unless GitHub Pages redirects from the same account + repo.
echo
echo "── Sparkle ──────────────────────────────────────────────────────"
EXPECTED_FEED="https://rajnsingh99.github.io/devgentic/appcast.xml"
if [[ -f "$INFO_PLIST" ]]; then
  FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST" 2>/dev/null)"
  if [[ "$FEED" == "$EXPECTED_FEED" ]]; then
    pass "SUFeedURL = $FEED"
  else
    fail "SUFeedURL is '${FEED:-<unset>}', expected $EXPECTED_FEED"
  fi
  EDKEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null)"
  if [[ ${#EDKEY} -eq 44 ]]; then
    pass "SUPublicEDKey is present"
  else
    fail "SUPublicEDKey is missing or malformed — Sparkle refuses to start without it"
  fi
  if /usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$INFO_PLIST" >/dev/null 2>&1; then
    fail "SUEnableAutomaticChecks is set — automatic checks must be the user's choice (PRIVACY.md)"
  else
    pass "SUEnableAutomaticChecks absent — Sparkle asks the user first"
  fi
fi

# ------------------------------------------------------------------ built app
if [[ -n "$APP_PATH" ]]; then
  echo
  echo "── Built app: $APP_PATH ─────────────────────────────────────────"
  if [[ ! -d "$APP_PATH" ]]; then
    fail "no such app bundle: $APP_PATH"
  else
    SIGINFO="$(codesign -dvvv "$APP_PATH" 2>&1)"

    if printf '%s' "$SIGINFO" | grep -q 'Authority=Developer ID Application'; then
      pass "signed with a Developer ID Application certificate"
    elif printf '%s' "$SIGINFO" | grep -q 'Signature=adhoc'; then
      fail "the built app is AD-HOC signed — keychain ACLs will not survive an update"
    else
      fail "not signed with Developer ID (authority: $(printf '%s' "$SIGINFO" | sed -n 's/^Authority=//p' | head -1))"
    fi

    APP_EXEC="$APP_PATH/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
    APP_ARCHS="$(lipo -archs "$APP_EXEC" 2>/dev/null)"
    if [[ "$APP_ARCHS" == "arm64" ]]; then
      pass "executable is arm64 only"
    else
      fail "executable architectures are '${APP_ARCHS:-<unreadable>}', expected arm64 only"
    fi

    if [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
      pass "Sparkle.framework is embedded"
    else
      fail "Sparkle.framework is not embedded — the app cannot update itself"
    fi

    APP_TEAM="$(printf '%s' "$SIGINFO" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$APP_TEAM" == "$EXPECTED_TEAM_ID" ]]; then
      pass "TeamIdentifier = $APP_TEAM"
    else
      fail "TeamIdentifier is '${APP_TEAM:-<none>}', expected $EXPECTED_TEAM_ID"
    fi

    # Every nested code bundle must carry the SAME team. Under the hardened runtime, library
    # validation makes dyld refuse a framework signed by another team — the app dies at launch,
    # before any UI. SPM binary targets (ObjectBox, CodeLanguages_Container, Sparkle) arrive
    # pre-signed by their vendors and are the ones that can slip through un-re-signed.
    # ⚠️ A plain `xcodebuild build` re-signs Sparkle.framework but NOT the helpers inside it
    # (Updater.app, Autoupdate, Downloader.xpc, Installer.xpc) — they keep Sparkle's ad-hoc
    # signature and notarization rejects them. Only archive → export (developer-id) re-signs them,
    # so run this gate on the EXPORTED app. Symlinks are skipped: Sparkle.framework/Updater.app is
    # a link to Versions/B/Updater.app and would otherwise be reported twice.
    while IFS= read -r -d '' nested; do
      NESTED_TEAM="$(codesign -dvv "$nested" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
      REL="${nested#"$APP_PATH"/}"
      if [[ "$NESTED_TEAM" == "$EXPECTED_TEAM_ID" ]]; then
        pass "nested $REL"
      else
        fail "nested $REL has TeamIdentifier '${NESTED_TEAM:-<none>}' — dyld will refuse to load it under library validation"
      fi
    done < <(find "$APP_PATH/Contents" ! -type l \
               \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.dylib' -o -name 'Autoupdate' \) \
               -not -path '*/Versions/*/Resources/*' -print0 2>/dev/null)

    # CodeDirectory flags carry `runtime` when the hardened runtime is on.
    if printf '%s' "$SIGINFO" | grep -q 'flags=.*runtime'; then
      pass "hardened runtime is enabled in the signature"
    else
      fail "the signature does not carry the 'runtime' flag — not notarizable"
    fi

    # ⚠️ get-task-allow lets a debugger attach. Xcode injects it automatically for DEBUG builds, so
    # seeing it here means a Debug-signed product is being passed off as a release. Notarization
    # rejects it outright, and it would also let any local process read the app's memory — including
    # the decrypted credentials it just fetched from the keychain.
    EMBEDDED_ENTS="$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null)"
    if printf '%s' "$EMBEDDED_ENTS" | grep -q 'get-task-allow'; then
      fail "com.apple.security.get-task-allow is embedded — this is a DEBUG-signed build; notarization will reject it"
    else
      pass "no get-task-allow entitlement"
    fi

    # The four Resource Access keys must survive into the SIGNED binary, not just the source file.
    for key in \
      com.apple.security.device.audio-input \
      com.apple.security.automation.apple-events \
      com.apple.security.personal-information.calendars \
      com.apple.security.personal-information.addressbook
    do
      if printf '%s' "$EMBEDDED_ENTS" | grep -q "$key"; then
        pass "embedded: $key"
      else
        fail "embedded entitlements are MISSING $key — a hand-rolled codesign without --entitlements drops them all"
      fi
    done

    if printf '%s' "$SIGINFO" | grep -q 'Timestamp='; then
      pass "signature carries a secure timestamp"
    else
      warn "signature has no secure timestamp"
    fi

    # The designated requirement is what the keychain ACL binds to. It must be anchored on the
    # Team ID, not on a cdhash — a cdhash-anchored DR is exactly the ad-hoc failure mode.
    DR="$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "$DR" ]]; then
      if printf '%s' "$DR" | grep -q 'anchor apple generic'; then
        pass "designated requirement is anchored on Apple's root + Team ID (stable across re-signs)"
      elif printf '%s' "$DR" | grep -q 'cdhash'; then
        fail "designated requirement is cdhash-anchored — it changes every build, breaking keychain ACLs"
      else
        warn "unrecognised designated requirement: $DR"
      fi
    else
      warn "could not read the designated requirement"
    fi
  fi
fi

echo
if (( FAILURES > 0 )); then
  printf '\033[31m%d failure(s) — this build must not ship.\033[0m\n' "$FAILURES"
  echo "Release builds must be signed with a Developer ID Application certificate:"
  echo "an ad-hoc signature has no stable designated requirement, so each build reads"
  echo "as a different application to the Keychain items the previous one created."
  exit 1
fi
printf '\033[32mRelease signing gate passed.\033[0m\n'

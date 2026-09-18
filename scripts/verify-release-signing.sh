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

# 2. Hardened runtime — required for notarization.
if printf '%s' "$BLOCK" | grep -q 'ENABLE_HARDENED_RUNTIME = YES;'; then
  pass "ENABLE_HARDENED_RUNTIME = YES"
else
  fail "Release does not set ENABLE_HARDENED_RUNTIME = YES — the build cannot be notarized"
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

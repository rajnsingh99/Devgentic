# Contributing to Devgentic

Thanks for the interest. This is a one-maintainer project, so the process is deliberately light — but two
things are fixed: **discussion before code**, and **a signed CLA before a merge**.

## Discussion first

Open an issue before writing a pull request, unless the change is a one-line fix. Say what you want to
change and why. Agreeing on the shape of a change before the work is done is what keeps this fast for
both of us; an unannounced large PR is the one thing most likely to be closed unmerged.

Bug reports: the app can export a diagnostic bundle (the "Report on GitHub" button in the export sheet
pre-fills an issue). Include it.

## Contributor Licence Agreement

Every contribution — code, tests, docs — requires the [Individual Contributor Licence Agreement](CLA.md).
It grants the maintainer the right to distribute your contribution under the project's licence *and*
under other terms; that is what keeps a single-copyright-holder project able to relicense, and it is a
condition of merging, with no exceptions.

To sign, add this line to your pull-request description, verbatim:

> I have read the CLA Document and I hereby sign the CLA

(When the CLA bot is enabled on the repository it will ask for the same sentence as a comment, and record
it. Signing once covers all your future contributions.)

## Licence headers

Every new `.swift` file starts with exactly these two lines:

```swift
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
```

Keep them on files you touch. Files under `generated/` are produced by the ObjectBox generator and carry
no header — don't add one, it would be lost on the next run.

## Building and testing

`README.md` has the build and test commands. Two things that bite newcomers:

- **Don't run the whole test suite casually** — parts of it load Whisper models and drive real
  embedding models. Find the classes you need and target them with `-only-testing:`.
- **The Release configuration signs with the maintainer's Developer ID** (team `FM3V43ST5B`), so it
  fails on any other machine. Build Debug for day-to-day work; to build Release from source, sign ad hoc
  instead: `xcodebuild -configuration Release DEVGENTIC_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`.
- **ObjectBox code generation is manual.** After changing a property on an ObjectBox entity, re-run the
  generator plugin; the failure mode when you don't is a confusing "instance member cannot be used on
  type" error at the new property's query accessor, not a missing-file error.

## Conventions worth knowing

- **Tools are declared in the catalogue, never registered ad hoc.** Adding a native tool means a
  `NativeToolCatalog` entry; a stray `case` or `registerNative(…)` fails `ToolRegistryDriftTests`.
- **Logging is for the person debugging from logs alone.** A bracketed tag, a correlation ID, and — for
  every silent skip, drop or teardown — the *consequence* of it. Match the density of the surrounding
  code.
- **`assert` is stripped in release builds.** Pair every invariant assertion with a `logger.error`.
- Match the surrounding code's naming, comment density and idiom rather than importing your own.

## Releases

Maintainer-only, but the rules live here so they are written down somewhere:

- `MARKETING_VERSION` is semantic: `MAJOR.MINOR.PATCH`.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is the build number, formatted `YYYYMMDDNN` — the build
  date plus a two-digit sequence. It must **strictly increase** with every published build, because the
  in-app updater compares it; a release that reuses or lowers it will never be offered to anyone. The
  release script sets it; don't edit it by hand.
- Ship only an app produced by **archive → export** (`method = developer-id`), and run
  `scripts/verify-release-signing.sh <exported .app>` on it first. A plain `xcodebuild build` leaves
  Sparkle's nested helpers carrying Sparkle's own ad-hoc signature, which notarization rejects.
- The Sparkle EdDSA private key is in the maintainer's login Keychain (`generate_keys`, default account)
  **and** in an offline backup. It cannot be regenerated: `SUPublicEDKey` in `Devgentic/Info.plist` is
  compiled into every installed copy.

## Naming and trademark

**Devgentic** is a trademark of Raj Singh, and the AGPL grants no trademark rights. You are free to fork
and redistribute the code; a redistributed or modified build must carry a different name and must not
imply endorsement. See the [naming note in the README](README.md#trademark-and-naming).

**A fork must also replace `SUFeedURL` and `SUPublicEDKey`** in `Devgentic/Info.plist` (or remove
Sparkle). Left as they are, the fork checks the official feed and offers to replace itself with the
official build.

If you are contributing *to* this project rather than forking it, this does not affect you — it exists so
that a build calling itself "Devgentic" is one users can trace back to here.

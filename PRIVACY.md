# Devgentic Privacy

Devgentic is **local-first**. It has no backend and sends no analytics or telemetry
anywhere on its own. Your conversations, files, and configuration stay on your Mac.

## On-device diagnostics

To make problems reproducible and fixable, Devgentic records **sanitized diagnostic
traces** on this Mac:

- **What is recorded:** execution traces (spans, events, error chains), sanitized
  error- and warning-level log entries, per-run configuration snapshots, and aggregate
  reliability metrics. Only **error/warning** severity is recorded — that is the whole rule,
  and no other setting raises it. Info, notice, debug and trace messages go to the live
  Console stream only and are never written to disk or included in an export.
- **Where it lives:** a local SQLite database (`traces.sqlite`) inside the app's
  Application Support container. It never leaves your Mac unless *you* choose to export
  a diagnostic bundle (see below).
- **Sanitization:** text is passed through a redactor before it is stored or exported —
  home/file paths, IP addresses, email addresses, API keys, bearer tokens, and common
  secret values are replaced with placeholders.
- **Retention:** diagnostic traces and logs older than **30 days** are purged
  automatically at app launch. You can see the current on-disk size under
  **Settings → General → Developer → Diagnostics Storage**.

## Your control

- Diagnostic recording is **on by default** but is **opt-out**. Turn it off under
  **Settings → General → Developer → Store Diagnostic Traces**. With it off,
  error/warning logs, error analytics, and crash diagnostics stop being recorded — this
  opt-out is absolute and no other setting overrides it.
  Basic execution traces (what ran, when, with what outcome) are still kept locally —
  they power the in-app Report inspector — and are purged after 30 days. Deleting a
  conversation deletes its traces and logs immediately.
- Recording is **on-device only**. Nothing is transmitted automatically.

## Sharing a problem report

When you choose **Export Feedback Report** (or, in Developer Mode, **Export Bundle**),
Devgentic assembles a `.zip` diagnostic bundle and lets you save it. Everything in the
bundle is sanitized at export time at your chosen level (Minimal / Standard / Strict),
and a `SANITIZATION_NOTICE.txt` describes exactly what was redacted.

The bundle is **not uploaded anywhere automatically**. If you use the **Report on
GitHub** button, it opens a pre-filled issue in your browser and asks you to attach the
zip you saved — you decide whether and where to share it. An optional screenshot is
included only if you explicitly add one, and may contain whatever was on screen.

## What is *not* collected

- No background telemetry, usage analytics, or crash phone-home.
- No account, advertising identifier, or device fingerprint.
- Nothing is sent to Anthropic or to the Devgentic maintainers unless you explicitly
  export and share a diagnostic bundle.

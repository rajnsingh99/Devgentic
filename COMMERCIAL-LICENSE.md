# Commercial licensing

Devgentic is published under the **GNU Affero General Public License v3** (`AGPL-3.0-only`). That is the
licence for everyone, and for most uses it is the only one you need.

This page exists for the cases where AGPL genuinely does not work, and explains how to ask about
alternative terms without opening a public issue.

---

## First: you probably don't need one

The AGPL is more permissive than its reputation suggests. **None of these require a commercial licence:**

| What you're doing | Under AGPL |
|---|---|
| Running Devgentic at work, unmodified | ✅ Fine |
| **Modifying it and deploying it across your company** | ✅ Fine — internal use is not distribution |
| Building internal tools on top of it, never shipped outside | ✅ Fine |
| Charging your own users for support or hosting an *unmodified* copy | ✅ Fine |
| Contributing changes back | ✅ Fine, and welcome |

The obligation is triggered by **distribution** and by **network service**, not by use. If your modified
copy never leaves your organisation, you owe nothing and there is nothing to discuss.

Please don't start a licensing conversation you don't need — it costs us both time, and the answer above
is free.

## When you do need one

Two situations:

1. **You want to ship a derivative work without publishing its source.** Embedding Devgentic, or parts of
   it, in a product you distribute under closed terms.
2. **You want to offer a modified Devgentic as a network service** to people outside your organisation.
   This is AGPL §13 — the "Affero" clause — and it is deliberate here: the Slack, Discord and Telegram
   bridges make "run it as a hosted service" a realistic deployment, and §13 is what keeps that open.

There is also a third, less technical case that is entirely legitimate: **your legal department has a
blanket policy against AGPL**, regardless of what the licence actually requires. That is a real constraint
and a reasonable reason to ask.

## What can be offered

The copyright in Devgentic is held by a single author, and every contribution is covered by the
[Contributor Licence Agreement](CLA.md). That means alternative terms are actually possible to grant —
in a project with scattered copyright they would not be.

What that makes available, by negotiation:

- A licence to distribute a derivative work under your own terms
- A licence to operate a modified version as a network service
- A written warranty or indemnity, which the AGPL explicitly disclaims

What is **not** available: exclusivity, or any arrangement that would stop Devgentic continuing as free
software under AGPL. The public project is not for sale and will not be withdrawn.

## How to ask

Email **dev.rajnsingh99@gmail.com** with `Devgentic licensing` in the subject.

Please don't raise it as a GitHub issue — those are public, and your interest in a commercial licence is
usually something you would rather not announce.

To make the first reply useful, include:

- What you want to do that AGPL doesn't permit — the specific obligation that blocks you
- Whether it is distribution, network service, or a policy constraint
- Rough scale: internal tool, a product you sell, a hosted service, number of end users
- Any timeline you're working to

Expect a reply within a week. This is a one-maintainer project, not a licensing desk, so the first
exchange will be a genuine conversation rather than a price list.

## Due diligence

If your review needs it, the following are already in place and public:

- [`LICENSE`](LICENSE) — the full AGPL-3.0 text; every source file carries a matching SPDX header
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — every bundled dependency with its licence text.
  All are permissive (MIT / Apache-2.0 / BSD). Nothing copyleft, nothing non-commercial
- [`CLA.md`](CLA.md) — the agreement covering every contribution
- [`SECURITY.md`](SECURITY.md) — the threat model and reporting process
- [`PRIVACY.md`](PRIVACY.md) — the app is local-first with no telemetry and no backend of its own

One thing worth stating plainly, because diligence usually asks: the repository contains no third-party
copyrighted assets. Bundled fonts, templates and sample media were audited and replaced with content
written for this project.

---

*Devgentic is a trademark of Raj Singh. The AGPL grants no trademark rights — see the naming note in
[`README.md`](README.md#trademark-and-naming).*

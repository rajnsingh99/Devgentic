# devgentic.github.io — the Devgentic website

This branch is **only** the public website. It shares no history with `develop`; the app source is
on that branch and never appears here.

Served by GitHub Pages at <https://rajnsingh99.github.io/devgentic/>.

## How this is checked out

This is an orphan branch attached as a git worktree, so the site and the app are both on disk at
once without switching branches:

```
Devgentic/          develop      — the macOS app
devgentic-site/     gh-pages     — this site
```

Recreate it after a fresh clone with:

```bash
git worktree add ../devgentic-site gh-pages
```

## Publishing

There is no build step and no CI. Committing and pushing this branch *is* the deploy — GitHub Pages
rebuilds within a minute or two.

```bash
git add . && git commit -m "…" && git push origin gh-pages
```

## What lives here

| Path | Purpose |
|---|---|
| `index.html` | The landing page |
| `appcast.xml` | The Sparkle update feed. ⚠️ **Compiled into every shipped binary** as `SUFeedURL` — the filename and location cannot change once a release exists. |
| `assets/` | Screenshots, the demo GIF, icons |
| `.nojekyll` | Stops GitHub running Jekyll over the site, which would ignore any `_`-prefixed file |

## Two things not to break

1. **The download link** is `https://github.com/rajnsingh99/devgentic/releases/latest/download/Devgentic.dmg`.
   It only resolves while the release asset keeps that exact filename and the release is **not** marked
   as a pre-release — GitHub excludes pre-releases from `latest`.
2. **Keep real content in the HTML.** Anything rendered client-side from JS is invisible to link
   unfurlers, so a page shared to Slack, Discord, Reddit or X would preview as blank.

# Security

## What counts as a vulnerability here

Devgentic is a **local tool that runs with your own user's privileges, doing what you configured it to
do.** That is the design, not an oversight: an Agent profile with `run_command` enabled can run shell
commands because you gave it that tool. A report of the form "the user can make the app do something to
the user's own machine" is not a vulnerability — it is the product.

What **is** in scope is anything reachable from input you did *not* author:

- A **Slack, Discord or Telegram** message steering a run beyond what the human-in-the-loop gates allow
  (the ChatOps bridges are the one place a third party's text enters the system).
- An **MCP server's** responses, or a **model's output**, escaping the approval tier of a tool call.
- **Prompt or tool-argument injection** that reaches a shell, the filesystem, or the network without the
  approval the tool's risk tier requires.
- The **update mechanism** — anything that would let a build not signed by the maintainer be installed
  as an update.
- The website and download path.

## Reporting

Please **do not open a public issue** for a vulnerability. Use GitHub's private vulnerability reporting
on this repository (*Security* tab → *Report a vulnerability*), which reaches the maintainer directly.
Include the version (About window), the profile configuration involved, and a reproduction.

You will get an acknowledgement, a fix or a reasoned "won't fix", and credit in the release notes if you
want it. There is no bounty programme; this is a one-maintainer open-source project.

## Supported versions

Only the latest release. Fixes ship as a new version through the in-app updater; there are no backports.

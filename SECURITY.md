# Security

## Reporting a problem

Please report security problems privately, through **Report a vulnerability** on this repository's [Security tab](https://github.com/hazlijohar95/consolidatex/security/advisories/new), not in a public issue. Say what an attacker controls, what they gain, and how to reproduce it.

Fixes go into `main` and the next release.

## What's sensitive here

Consolidatex sits next to the logins of every Claude Code, Codex and opencode account on a machine, so these are worth a report:

- A login token reaching anything other than Anthropic's usage endpoint: a log, an error message, a notification, a file, `acc ls --json`, or another process.
- Text from a file another program writes (account names, folder paths, conversation ids, transcripts) running as shell code. acc writes shell code into your startup file through `acc shell-init`, and the app runs `acc continue` in a terminal.
- Another app or a web page making Consolidatex act through its `consolidatex://` URL.
- Changes to files outside the account folders, `~/.config/acc`, your shell's startup file and Claude Code's `settings.json`.

[What acc reads and sends](README.md#what-acc-reads-and-sends) lists everything acc reads and where it sends it, including one known exposure: sharing MCP servers passes their definitions to `claude` as a command-line argument, which other users on a shared Linux machine can see unless `/proc` hides other users' processes.

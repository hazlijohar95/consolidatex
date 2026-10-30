# Consolidatex

Run several subscriptions of Claude Code, Codex and opencode on one Mac, and pick which one each new session uses. A menu bar panel shows every account's usage. The `acc` command does the same from the terminal.

```
$ acc ls
  1  claude    team      Haz (team)      me@company.com   5h 2% · 7d Fable 35%
● 2  claude    personal  Haz (Personal)  me@gmail.com     5h 14% · 7d 55% · 7d Fable 18%
  3  claude    cto       CTO             cto@company.com  5h 100% · 7d Fable 75% · resets in 1h
● 4  codex     plus      ChatGPT Plus    me@gmail.com     5h 40% · 7d 12%
● 5  opencode  default   opencode                         no usage data
```

The `●` marks the account that new sessions of that tool start on.

## Install

```
brew install hazlijohar95/tap/consolidatex
acc setup
```

Homebrew builds Consolidatex from source, so the app opens without a Gatekeeper prompt. It needs macOS 14 or later. If Homebrew says your Command Line Tools are out of date, update them in **System Settings › Software Update** first.

`acc setup` asks before each step:

1. Import the accounts you already have: `~/.claude`, `~/.claude-*`, `~/.codex`, `~/.codex-*`, and opencode. Names come from T3 Code when it has them, else from the email you're logged in with.
2. Add one line to your shell's startup file (zsh, bash or fish), so `claude`, `codex` and `opencode` start on the account you picked.
3. Turn on the Claude Code status line, which shows each session's account and usage.
4. Share your rules, settings, skills, plugins and MCP servers from each tool's main account with its other accounts. The main account is the one in the tool's usual folder, such as `~/.claude`.
5. Put the menu bar app in `~/Applications`.

You can run `acc setup` again at any time. It only adds what's missing.

To build from source instead, you need Xcode or the Command Line Tools:

```
git clone https://github.com/hazlijohar95/consolidatex && cd consolidatex
script/install && acc setup
```

## Pick an account

Click an account in the menu bar panel, or run `acc <name>`. The next `claude`, `codex` or `opencode` you start, in any terminal, runs on that account. Sessions that are already running keep theirs.

To run one session on another account without switching, put the account after `@`:

```
claude @work
```

`<name>` can be the account's id, its position in `acc ls`, or any part of its name or email that matches only one account.

To switch from anywhere, press **⌥⌘A**. Use the arrow keys to choose an account, then press Return.

## When an account hits its limit

When the account new sessions start on hits a limit, Consolidatex moves new sessions to the account with the most tokens left and tells you. When the first account resets, it moves them back. Picking an account yourself ends the move. To turn this off, open the panel's **⋯** menu and clear **Switch Automatically at a Limit**.

If you were in a conversation on that account, the notification offers to continue it. Click it, and Terminal opens in that conversation's folder and runs `acc continue` to resume the conversation on the other account. The account's row in the panel offers the same.

## See your week

Open **Last 7 Days…** from the panel's **⋯** menu, or run `acc report`. For each account it shows how much of its weekly limit you used and how long it sat at a limit. It also points out accounts that were mostly idle and accounts that kept hitting their limit. The app records usage every 15 minutes while it runs, so the report fills in over the first week.

## Watch your usage

The menu bar shows the usage of the account you're working in. Click it for the panel:

- Each account shows its 5-hour usage as a bar and its other limits as percentages, with a countdown to the next reset.
- **Next session** marks the account new sessions start on. **Most tokens left** marks the account with the most of its limits unused.
- A yellow line warns when an account will hit a limit before it resets, at its current pace.
- You get a notification when a capped account resets.
- Right-click an account to rename it, log it in again, or show its folder in Finder.

New account folders show up in the panel by themselves. `acc rm` keeps one out for good.

Where the numbers come from, by tool:

- **Claude Code:** each session's status line. For accounts you aren't using, turn on **Live Claude Usage from Anthropic** in the panel's **⋯** menu. It reads each account's login from the keychain and asks Anthropic for that account's limits every 5 minutes. macOS may ask once per account for keychain access.
- **Codex:** Codex's session files, plus a request to Codex itself every 5 minutes. Codex makes that request with its own login.
- **opencode:** opencode doesn't report usage.

## Commands

| Command | What it does |
|---|---|
| `acc` | Pick an account with fzf. Press 1–9 to jump. |
| `acc <name>`, `acc codex <name>` | Make it the account new sessions start on. |
| `claude @<name> …` | Run one session on another account. |
| `acc ls [--json]` | List accounts with their last known usage. |
| `acc auto` | Switch each tool to its account with the most tokens left. |
| `acc report` | Show the last 7 days: weekly use and hours at a limit, per account. |
| `acc continue [<name>]` | Move this folder's latest conversation to another account and resume it there. Claude Code and Codex only. |
| `acc add codex "Client A"` | Add a subscription: a new folder, shared config, then the tool's own login. |
| `acc login`, `acc rename`, `acc rm` | Log an account in again, rename it, or take it out of the list. `rm` keeps its folder. |
| `acc doctor [--fix]` | Check logins, shared config and setup. |
| `acc sync [--prune]` | Share each tool's config from its main account again. |
| `acc ui` | Open the Manage window. |

`acc help` lists every option.

## What acc reads and sends

Each tool logs itself in and keeps its own credentials. acc never copies them.

- To name accounts, acc reads the email and plan from Claude Code's `.claude.json` and from the ID token in Codex's `auth.json`.
- The `acc` command and the status line make no network calls.
- The menu bar app asks Codex for its usage through `codex app-server`. Codex sends that request with its own login, so no credential passes through acc.
- With live Claude usage on, the app sends each Claude account's login token to Anthropic's usage endpoint, the one behind Claude Code's `/usage`, and nowhere else. It is off until you turn it on.

All state lives in `~/.config/acc/accounts.json`. Every change is checked before it's written and replaces the file in one step, so you can edit it by hand. `acc doctor` tells you if an edit broke it.

## If something's off

- **`claude` ignores the account you picked.** Open a new terminal. If it still does, run `acc doctor`. It reports a missing shell line.
- **An account shows "no usage yet".** Claude Code: use it once, or turn on live Claude usage. Codex: start a session on it.
- **The panel shows a red message under an account.** That's the last error from asking for its usage, such as an expired login. Run `acc login <name>`.
- **The app says a tool isn't installed.** The app looks for tools on your login shell's `PATH`. Check that `which claude` works in a new terminal.

Kiro CLI isn't supported. It keeps its login in one database that no setting can move, so separate Kiro accounts would need a different `HOME`, which affects every other tool.

## Develop

```
script/test       # unit tests, then end-to-end tests with stub tools in a throwaway HOME
script/install    # build and install the app and the CLI from source
```

[How Consolidatex works](docs/how-it-works.md) explains the design: the account model, switching, usage, discovery and the menu bar app. Read it before changing anything in `Sources/AccCore`.

`.github/workflows/release.yml` builds a release for every `v*` tag. Signing and notarizing turn on once the `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets exist. Publishing to the Homebrew tap turns on once `HOMEBREW_TAP_TOKEN` exists.

## License

MIT

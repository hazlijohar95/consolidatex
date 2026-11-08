# Consolidatex

Run several subscriptions of Claude Code, Codex and opencode on one computer, and pick which one each new session uses. On a Mac, a menu bar panel shows every account's usage. The `acc` command does the same from the terminal, on macOS and Linux.

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

Homebrew builds Consolidatex from source, so the app opens without a Gatekeeper prompt. Building it needs macOS 14 or later. If Homebrew says your Command Line Tools are out of date, update them in **System Settings › Software Update** first.

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

### Linux

The `acc` command works on Linux too; the menu bar app is macOS only. You need [Swift 6](https://www.swift.org/install/linux/) and zsh to build it, and libcurl to run it (most distributions ship it):

```
git clone https://github.com/hazlijohar95/consolidatex && cd consolidatex
script/install && acc setup
```

`script/install` links Swift's runtime into `acc`, so it keeps working if you update or remove Swift. Running sessions show the app they run in when your desktop starts apps in their own systemd units, as Omarchy (uwsm), GNOME and KDE do.

## Pick an account

Click an account in the menu bar panel, or run `acc <name>`. The next `claude`, `codex` or `opencode` you start, in any terminal, runs on that account. Sessions that are already running keep theirs.

To run one session on another account without switching, put the account after `@`:

```
claude @work
```

`<name>` can be the account's id, its position in `acc ls`, or any part of its name or email that matches only one account.

To switch from anywhere, press **⌥⌘A**. Use the arrow keys to choose an account, then press Return.

To open the usage panel from anywhere, press **⇧⌥⌘A**.

## When an account hits its limit

When the account new sessions start on hits a limit, Consolidatex moves new sessions to the account with the most tokens left and tells you. When the first account resets, it moves them back. Picking an account yourself ends the move. To turn this off, open the panel's **⋯** menu and clear **Switch Automatically at a Limit**.

If you were in a conversation on that account, the notification offers to continue it. Click it, and a terminal opens in that conversation's folder and runs `acc continue` to resume the conversation on the other account. The account's row in the panel offers the same, with a menu for which terminal: Terminal, Ghostty, iTerm or Rex, whichever you have. The one you pick opens from then on; **Open Conversations In** in the **⋯** menu changes it too.

To skip the click, turn on **Continue Conversations Automatically at a Limit** in the **⋯** menu. Then every conversation still going on the account opens on the account with the most left, in windows behind whatever you're doing, and is told: "The usage limit cut you off, and this conversation has moved to another account. Continue where you left off." So the work carries on without you. A notification says where each conversation went, or why it couldn't open. It's off until you turn it on, because it sends that message for you. It picks conversations by what was written in the last 10 minutes, so one you closed just before the limit can come back too.

## See your week

Open **Last 7 Days…** from the panel's **⋯** menu, or run `acc report`. For each account it shows how much of its weekly limit you used, how long it sat at a limit, and which apps used it. It also points out accounts that were mostly idle and accounts that kept hitting their limit. The app records usage every 15 minutes while it runs, so the report fills in over the first week.

## Watch your usage

The menu bar shows the usage of the account you're working in. Click it for the panel:

- Each account shows its 5-hour usage as a bar and its other limits as percentages, with a countdown to the next reset. A limit on one model, such as "7d Fable 100%", doesn't mark the account capped, because it keeps working on other models.
- **Next session** marks the account new sessions start on, which also has a blue line down its left edge. **Most left** marks the account with the most left on the limits all its models share.
- A line under an account warns when it will hit a limit before it resets, at its current pace, with the time in yellow.
- You get a notification when a capped account resets.
- Each account shows the icons of the apps running sessions on it now, such as Rex, T3 Code or Claude desktop, with a count when there's more than one.
- Click an account to see which apps are running on it and how its last 5 hours of tokens split between them, such as "T3 Code 68% · Terminal 22% · Claude desktop 10%". For an account that isn't the one new sessions start on, the same click offers the switch.
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
| `acc ls [--json]` | List accounts with their last known usage and the apps running on each now. `--json` adds per-account usage (load, windows, running apps), `configDirPath`, headroom rank, and a top-level `roomiest` map for tool-routing agents. |
| `acc auto` | Switch each tool to its account with the most tokens left. |
| `acc report` | Show the last 7 days: weekly use and hours at a limit, per account. |
| `acc continue [<name>] [--session <id>] [--prompt <text>]` | Move this folder's latest conversation, or the one with that id, to another account and resume it there, with `<text>` as its next message. Claude Code and Codex only. |
| `acc add codex "Client A"` | Add a subscription: a new folder, shared config, then the tool's own login. |
| `acc login`, `acc rename`, `acc rm` | Log an account in again, rename it, or take it out of the list. `rm` keeps its folder. |
| `acc doctor [--fix]` | Check logins, shared config and setup. |
| `acc sync [--prune]` | Share each tool's config from its main account again. |
| `acc ui` | Open the Manage window (macOS). |

`acc help` lists every option.

## What acc reads and sends

Each tool logs itself in and keeps its own credentials. acc never copies them.

- To name accounts, acc reads the email and plan from Claude Code's `.claude.json` and from the ID token in Codex's `auth.json`.
- The `acc` command and the status line make no network calls.
- The menu bar app asks Codex for its usage through `codex app-server`. Codex sends that request with its own login, so no credential passes through acc.
- To show which apps run which account, the app reads the running `claude`, `codex` and `opencode` processes. From each one's environment it takes only the variable that names its account folder, or, for Claude desktop's sessions, the account and organization IDs of its login. It never reads or keeps anything else, such as login tokens.
- With live Claude usage on, the app sends each Claude account's login token to Anthropic's usage endpoint, the one behind Claude Code's `/usage`, and nowhere else. It is off until you turn it on.
- On Linux there's no keychain, so the login comes from the `.credentials.json` Claude Code keeps in each account's folder.
- Sharing MCP servers (`acc setup`, `acc sync`, `acc add`) goes through `claude mcp add-json`, which takes each server's definition, keys included, only as a command-line argument. On a Linux machine other people log in to, they can see process arguments while it runs unless `/proc` is mounted with `hidepid=2`; on a Mac they can't.
- With automatic continue on, the app resumes your conversations in your terminal with the message above. That message is all it adds; the tool sends the conversation to its own servers as it always does.

All state lives in `~/.config/acc/accounts.json`. Every change is checked before it's written and replaces the file in one step, so you can edit it by hand. `acc doctor` tells you if an edit broke it.

## If something's off

- **`claude` ignores the account you picked.** Open a new terminal. If it still does, run `acc doctor`. It reports a missing shell line.
- **`acc add` stopped at the login.** The account is already in the list. Run `acc login <name>` to log it in.
- **An account shows "no usage yet".** Claude Code: use it once, or turn on live Claude usage. Codex: start a session on it.
- **The panel shows a red message under an account.** That's the last error from asking for its usage, such as a missing login. Run `acc login <name>`.
- **The panel says "updates when this account is next used".** The account is logged in, but Claude Code renews the token the usage check needs only when the account is used. The panel keeps the last reading until then.
- **The app says a tool isn't installed.** The app looks for tools on your login shell's `PATH`. Check that `which claude` works in a new terminal.

Kiro CLI isn't supported. It keeps its login in one database that no setting can move, so separate Kiro accounts would need a different `HOME`, which affects every other tool.

## Develop

You need Xcode or the Command Line Tools, and Docker to run the Linux tests.

```
script/test       # unit tests, then end-to-end tests with stub tools in a throwaway HOME
script/linux      # the same tests in a Linux container
script/install    # build and install the app and the CLI from source
```

The code is in three layers: `Sources/AccCore` is the model and everything the CLI and app share, `Sources/acc` is the command, and `Sources/Consolidatex` is the menu bar app. [How Consolidatex works](docs/how-it-works.md) explains the design: the account model, switching, usage, discovery and the menu bar app. Read it before changing anything in `Sources/AccCore`.

To see the panel without clicking the menu bar, run a debug build with `--show-panel`; it opens the panel at launch.

To report a security problem, see [SECURITY.md](SECURITY.md).

`.github/workflows/release.yml` builds a release for every `v*` tag. Signing and notarizing turn on once the `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets exist. Publishing to the Homebrew tap turns on once `HOMEBREW_TAP_TOKEN` exists.

## License

MIT

# Consolidatex

Run several subscriptions of **Claude Code**, **Codex** and **opencode** side by side on one Mac, and switch between them from the terminal or the menu bar.

```
$ acc
● 1  claude    work      Work             me@company.com      5h 82% · 7d 40% · resets in 1h
  2  claude    personal  Personal         me@gmail.com        5h 3% · 7d 12%
● 3  codex     plus      ChatGPT Plus     me@gmail.com        5h 40%
● 4  opencode  default   opencode         OpenAI              no usage data
```

- **Pick once, applies everywhere.** `acc personal` changes which account every new `claude` in every terminal starts on. Sessions that are already running keep their account.
- **Run two at once.** `claude @work` starts one session on another account without switching.
- **Out of quota mid-task?** `acc continue` resumes the conversation in this folder on the account with the most room left (Claude Code and Codex).
- **See usage at a glance.** Each Claude Code session's status line shows its account, its 5-hour and weekly usage, and which account to move to. The menu bar and `acc ls` show usage for every account.
- **One config.** Your rules, settings, skills, plugins and MCP servers are shared across all accounts of a tool, so a new account behaves like your existing ones.

## Install

```
brew install hazlijohar95/tap/consolidatex
acc setup
```

Homebrew builds Consolidatex from source in about a minute, so the app opens without Gatekeeper prompts. It needs macOS 14 or later. If Homebrew says your Command Line Tools are outdated, update them in System Settings › Software Update first.

`acc setup` does the following, asking before each change:

1. Finds the accounts you already have: `~/.claude`, `~/.claude-*` (including names from T3 Code), `~/.codex`, `~/.codex-*` and opencode.
2. Hooks up your shell (zsh, bash or fish), so `claude`, `codex` and `opencode` start on the account you picked.
3. Turns on the Claude Code status line.
4. Shares config across accounts.
5. Adds the menu bar app to `~/Applications`. After a `brew upgrade`, `acc doctor` tells you when the app needs refreshing.

Run it again at any time. It only adds what's missing.

**From source** (needs Xcode or the Command Line Tools):

```
git clone https://github.com/hazlijohar95/consolidatex && cd consolidatex
script/install && acc setup
```

## Use

| | |
|---|---|
| `acc` | pick an account (fzf; press 1–9 to jump) |
| `acc work` / `acc codex plus` | switch, across all tools or within one |
| `claude @work …` | one session on another account |
| `acc auto` | switch each tool to its account with the most room |
| `acc continue [account]` | move this folder's latest conversation to another account and resume it |
| `acc add codex "Client A"` | add a subscription: new folder, shared config, browser login |
| `acc ls`, `acc doctor`, `acc sync` | list, check, re-share config |
| `acc ui` | open the window: add, rename, reorder, log in, usage bars |

`acc help` has the full list.

## How it works

Each account is a separate folder. acc points the tool at that folder through the tool's own setting:

| Tool | Account folder | Selected with | Usage from |
|---|---|---|---|
| Claude Code | `~/.claude-<id>` | `CLAUDE_CONFIG_DIR` | the status line (`rate_limits`) |
| Codex | `~/.codex-<id>` | `CODEX_HOME` | `token_count` events in Codex's session files |
| opencode | `~/.opencode-<id>` | `XDG_DATA_HOME`, plus `--standalone` for a private server | not available |

The account on a tool's normal folder (`~/.claude`, `~/.codex`) runs with nothing changed.

Each tool logs itself in and keeps its own credentials, and acc never copies or sends them. The one thing acc reads is the email and plan claims in Codex's `auth.json` ID token, which it uses to label the account. Usage comes only from what the tools already write locally, so acc itself makes no network calls.

The shell hook defines `claude`, `codex` and `opencode` as functions that call `acc launch <tool>`. That command picks the tool's current account and replaces itself with the real binary. If acc's registry is missing or broken, the tool still starts on its default account and prints a warning.

All state is in `~/.config/acc/accounts.json`. The CLI and the app validate every change before writing and replace the file atomically, so it is safe to edit by hand, and `acc doctor` tells you if an edit broke anything.

**Not supported yet:** Kiro CLI keeps its login in a single database that no setting can move, so running Kiro accounts side by side isn't possible without changing `HOME`, which affects every other tool.

## Develop

```
script/test       # unit tests, then end-to-end tests against stub tools in a throwaway HOME
script/install    # build and install the app and CLI from source
```

`Sources/AccCore` holds the model. It defines the tool table (`Tool.swift`), the registry and its editing rules, and the per-tool support files. The CLI (`Sources/acc`) and the menu bar app (`Sources/Consolidatex`) are both thin layers over it.

To add a tool, add a `ToolSpec` and a `<Tool>Support` file, then extend the switches the compiler points you to.

Releases are built by `.github/workflows/release.yml` whenever a `v*` tag is pushed:

- **Signing and notarizing** turns on once the `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets exist.
- **Updating the Homebrew tap** turns on once the `HOMEBREW_TAP_TOKEN` secret exists. The tap gets a formula that builds the tagged source.

## License

MIT

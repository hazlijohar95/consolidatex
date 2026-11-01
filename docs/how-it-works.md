# How Consolidatex works

Consolidatex gives Claude Code, Codex and opencode more than one account each, without changing the tools. This doc explains how, for someone about to change the code. It covers the account model, how a session lands on an account, where usage numbers come from, how accounts are found, and how the menu bar app keeps up.

## One folder per account

Every one of these tools already has a setting that moves all of its state to another folder. Consolidatex treats each such folder as an account and never patches the tool itself.

| Tool | Variable | Default folder | New accounts |
|---|---|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` | `~/.claude`, plus `~/.claude.json` | `~/.claude-<id>` |
| Codex | `CODEX_HOME` | `~/.codex` | `~/.codex-<id>` |
| opencode | `XDG_DATA_HOME` | `~/.local/share` | `~/.opencode-<id>` |

The account on a tool's default folder runs with the variable unset. Setting it explicitly is not the same thing for Claude Code. `CLAUDE_CONFIG_DIR=~/.claude` points Claude Code at a different state file and a different keychain item than leaving it unset. opencode accounts other than the default also get `--standalone`, so each runs its own server instead of sharing the default account's.

`ToolSpec` in `Sources/AccCore/Tool.swift` holds all of this per tool: the command, the variable, the folders, the login arguments, and the files that accounts share. Every other part of the code reads the table instead of naming tools.

## Three layers

- `Sources/AccCore` is the model. It has no UI and no process-wide state. It holds the account registry, the rules for changing it, the per-tool knowledge, and usage.
- `Sources/acc/main.swift` is the `acc` command. It parses arguments and calls AccCore.
- `Sources/Consolidatex` is the menu bar app. `Model` owns the registry state and `UsageMonitor` owns usage. The SwiftUI views are `UsagePanel` and `AccountsView`.

A rule that both the CLI and the app need belongs in AccCore. If a view starts deciding what counts as an account, a folder or a limit, move that decision down.

## The registry

`~/.config/acc/accounts.json` is the only state Consolidatex owns. `$ACC_HOME` moves it, which the tests use.

```json
{
	"version": 2,
	"accounts": [
		{ "id": "team", "tool": "claude", "label": "Haz (team)", "email": "me@company.com" },
		{ "id": "personal", "tool": "claude", "label": "Haz (Personal)", "configDir": "~/.claude-acc2" }
	],
	"current": { "claude": "personal" },
	"removed": [{ "tool": "codex", "configDir": "~/.codex-old" }]
}
```

- `configDir: null` means the tool's default folder.
- `current` names the account each tool's next session starts on.
- `removed` lists folders that `acc rm` took out, so discovery doesn't add them back. `Registry.Removed.matches` compares folders after expanding `~` and resolving symlinks, so `~/.codex-old` and `/Users/me/.codex-old` count as the same folder.

`Registry.validate()` rejects a registry where ids are invalid or repeat, where a tool has no current account, or where two accounts of one tool share a folder. `RegistryStore.save` validates before it writes. It writes a temporary file next to `accounts.json`, then renames it over the original, so a reader never sees half a file. Changes go through `RegistryStore.update`, which reads the file, applies the change, and saves only if something changed, so a change that makes no difference doesn't wake the app's file watcher. The edits that people make (`add`, `use`, `rename`, `remove`, `move`) are methods on `Registry` in `Editing.swift`. The CLI and the app share them, so both enforce the same rules.

## Starting a session on an account

`acc setup` adds one line to the shell's startup file, for example `eval "$(acc shell-init zsh)"`. That line defines `claude`, `codex` and `opencode` as shell functions, each of which runs `acc launch <tool> -- "$@"`.

`launch` in `main.swift` picks the account in this order:

1. If the first argument is `@name`, use that account once.
2. If the tool's variable is already set, for example inherited from a parent session, leave it alone.
3. Otherwise use the tool's current account.

`Runner.exec` then sets or unsets the variable and replaces the `acc` process with the real binary through `execv`. The tool ends up as a direct child of the shell, with no wrapper left running. If the registry is missing, the tool starts on its default account. If the registry is broken, `launch` prints the error, then starts the tool on its default account anyway. A broken `accounts.json` never stops `claude` from starting.

Picking an account only writes `current`. Nothing reaches running sessions, because their variable was fixed when they started.

## Shared config

Every account of a tool shares config with that tool's main account. The main account is the one on the default folder, or else the first one listed (`Registry.primary`). `Shared.link` symlinks each of the tool's `sharedItems` from the main account's folder into the other accounts' folders. For Claude Code these are `CLAUDE.md`, `settings.json`, `skills`, `agents`, `commands`, `plugins` and `hooks`. `Shared.link` never replaces a real file. It reports one instead, and `acc doctor` shows it.

Claude Code keeps user-scope MCP servers in each account's own `.claude.json`, so they can't be shared with a symlink. `Shared.sync` copies them instead, through `claude mcp add-json` and `claude mcp remove`, so Claude Code's own file locking applies.

## Usage

`Usage` in `Usage.swift` is one account's reading: a list of `Usage.Window` values and the time it was read. A window has a length in minutes, an optional model name for per-model limits ("7d Fable"), the percentage used, and a reset time. A window whose reset time has passed counts as 0% used.

Four sources write readings:

| Source | Tool | When |
|---|---|---|
| Claude Code's status line (`acc statusline`) | Claude Code | Every time Claude Code redraws it |
| `token_count` events in Codex's session files | Codex | Whenever Codex runs |
| Anthropic's usage endpoint (`ClaudeUsageAPI`) | Claude Code | Every 5 minutes, only with live Claude usage on |
| `codex app-server` (`CodexAppServer.swift`) | Codex | Every 5 minutes, in the menu bar app |

`UsageStore` keeps one file per account in `~/.config/acc/usage/`. `UsageStore.merge` folds a new reading into the stored one, using `Usage.merged(over:)`. Windows the new reading reports replace the stored ones. Windows it doesn't report are kept until they reset. The status line reports only the 5-hour and 7-day windows, and the API also reports per-model ones, so this rule keeps the per-model windows between API reads. Claude Code redraws its status line often, so `merge` rewrites an unchanged reading at most once a minute. For Codex, `Usages.usage(for:)` takes whichever of the stored reading and the session-file reading is newer.

The two live sources sit behind `LiveUsage`. `LiveUsage.fetch` asks the right service for one account. `LiveUsage.Schedule` spaces requests 5 minutes apart per account, and longer when a server sends `Retry-After`. The menu bar app saves the schedule, so restarting the app doesn't skip a wait. The two sources differ on consent. Codex asks OpenAI with its own login, so the app does it without asking. The Claude read sends the account's login token, so it waits for the user to turn it on.

Two decisions read from usage:

- `Registry.roomiest` suggests the account with the most of its limits left. It skips accounts at 90% or more. The status line shows the suggestion once the current account reaches 90%, and the panel marks it **Most tokens left**.
- `Usage.forecast` projects when a window fills if use continues at its average rate since the window opened. It reports nothing for a window under 10% used, a window less than a tenth of the way through, or a projection that falls in the past or within the window's last 5%. A 5-hour pace only holds while someone is working, so windows shorter than a day count only while the account is active.

## Following limits

The menu bar app acts on limits, not only shows them. After every refresh, `UsageMonitor` reports which accounts reached a limit and which came off one (`LimitChanges`). `Model.follow` then does three things:

1. **It moves new sessions.** `Registry.autoPick` in `AutoSwitch.swift` decides when. If a tool's current account is at a limit, it picks the account with the most left. A `Detour` records the move, from the account the person picked to the one the app chose. Once the picked account has room again, `autoPick` sends new sessions back along the detour. `Detour.after` keeps the person's pick across several moves in a row. A pick by hand, or a current account that no longer matches the detour, drops the detour, so the app never undoes someone's own choice.
2. **It offers to move the conversation.** For an account that hit its limit while active, `Sessions.latest` finds its newest conversation and the folder it ran in. The notification's **Continue There** action opens Terminal and runs `acc continue <target> --session <id>` in that folder.
3. **It announces resets** that the switch back didn't already announce.

Resets happen by the clock, not only when a new reading arrives, so this runs on every refresh rather than only when readings change.

## History and the weekly report

`UsageHistory` stores one sample per account every 15 minutes, as a JSON line in `~/.config/acc/usage/history/<id>.jsonl`. A sample holds the fullest window's share used and the fullest weekly window's share. The app prunes samples older than 35 days once per launch. `WeekReport` reads the last 7 days of samples. It reports the most of the weekly limit used, the hours spent at a limit, and how many hours the history covers. A gap longer than two samples means the app wasn't running, so it counts as two samples' worth. `WeekReport.note` names the one thing worth acting on: an account that was capped for an hour or more, or one that used under 15% of its week across at least 3 days of history. The app shows the report in the **Last 7 Days** window, and `acc report` prints it.

## Which app runs which account

Two sources answer this, one for now and one for the past.

`RunningSessions.scan` reads the process table. It lists this user's processes with `proc_listallpids` and reads each one's short record (`PROC_PIDT_SHORTBSDINFO`, 64 bytes), which also exists for root-owned processes such as `login`. Each tool's `ToolSpec` says what its processes look like: `processNames` (opencode's npm package runs `opencode.exe`), `versionedInstallDir` (Claude Code's native install runs a file named for its version, such as `2.1.314`, from `~/.local/share/claude/versions/`), `ignoredArguments`, and `loginVariables`. For each tool process, the scan reads the arguments and environment (`KERN_PROCARGS2`) into one 32 KB buffer that it reuses. Real sessions use 1 to 10 KB. The kernel cuts the data to fit without reporting it, so a buffer that comes back full is read again at `kern.argmax`. The scan takes only the variables the tool's spec names. Every other variable, login tokens included, is compared byte by byte and never turned into a string.

- The folder variable gives the account, through `Registry.account(for:configDir:)`.
- Claude desktop passes a login instead of a folder. Its sessions name that login in `CLAUDE_CODE_ACCOUNT_UUID` and `CLAUDE_CODE_ORGANIZATION_UUID`, and take the account whose `.claude.json` has the same `oauthAccount.accountUuid` and `organizationUuid`. Both IDs are needed. One person in two organizations has one user ID, so the user ID alone can't tell a team account from a personal one.
- The app is the highest `.app` bundle among the process's parents, the one closest to launchd. That is the app a person works in. A helper inside it reads as the app, and so does a session started from inside another, such as a `claude` that a Claude desktop session runs from its shell tool. `RunningSessions.knownApps` names Rex, T3 Code and Claude desktop by bundle id.
- `claude --chrome-native-host`, Claude Code's entry in `ignoredArguments`, is the Claude in Chrome bridge, not a session, so it is left out. A process whose direct parent has the same tool name is a wrapper's inner half, so it is left out too.

For the past, `TranscriptLog` files each reply's tokens under an `Origin` taken from the transcript's `entrypoint` and `cwd`: `claude-desktop`, `cli` (a terminal), and Agent SDK sessions in `~/.t3` (T3 Code). A transcript can't tell one terminal from another, so past terminal work shows as "Terminal". Each history sample keeps the tokens spent since the previous sample, by origin (`TranscriptLog.tokens(since:)`), so summing a week of samples gives exact shares without reading 7 days of transcripts again. The menu bar app publishes per-app counts (`AppCount`), not processes. The Agent SDK starts a new process per query, and counts that stay the same don't redraw the panel.

## Activity and identity

`TranscriptLog` is an actor that reads one Claude Code account's transcripts, `projects/**/*.jsonl`, subagents included. On each call it reports the output tokens and requests of the last 5 hours, plus the newest change to any transcript. It reads a transcript changed in the last 5 hours in full once. After that it reads only the bytes added since, so each refresh costs only the new lines. Finding new transcripts means opening every folder under `projects/`, so a full walk runs once a minute, before each history sample, and on a manual refresh; in between, only the transcripts already known are checked. Lines are found and filtered on the raw bytes, and only assistant replies are decoded, and only those inside the 5 hours are kept. An account counts as active when it wrote something in the last 3 minutes. For Codex and opencode, `Sessions.lastActive` reads the modification time of the newest rollouts or of opencode's database instead.

`Identity` reads who an account is logged in as without running the tool. For Claude Code it reads `oauthAccount` in `.claude.json`, where `organizationType: "claude_team"` becomes the plan "Team". For Codex it reads the claims in `auth.json`'s ID token.

## Discovery

`Discovery.find` lists account folders that aren't in the registry and weren't removed. It looks for the default folders, then for `~/.claude-*`, `~/.codex-*` and `~/.opencode-*` folders that hold the tool's files. A found account is named by the first of these that no other account uses:

1. Its T3 Code name, from `~/.t3/userdata/settings.json`.
2. The part of its email before the `@`.
3. That with the plan added, such as "me · Team".
4. Its folder name.

`acc setup` shows what it found and asks before adding it. The menu bar app adds found accounts by itself, every 60 seconds and on every registry change, but only for tools it can find. The search runs inside the same edit that saves the result. That way it always works from the file on disk, and a folder can't be added twice.

## The menu bar app

The app starts with launchd's short `PATH`, which misses tools installed through Homebrew, nvm, pnpm or mise. At launch, `LoginShell` runs the login shell once (`$SHELL -ilc`) and puts its `PATH` in front of the app's own. Every tool the app starts then sees what a terminal sees. A tool installed through npm needs this to find `node`. The shell writes the `PATH` to a temporary file rather than a pipe, because a background job started by an rc file can hold a pipe open after the shell exits. Slow shells get 10 seconds.

`Model` holds the registry. Every edit reads `accounts.json` from disk first, applies the change, and saves only if something changed. Skipping unchanged saves matters: a save wakes the folder watcher, the watcher reloads, and the reload runs discovery, which edits again. Without the check that cycle never stops.

`UsageMonitor` runs every 15 seconds and whenever the panel opens. It does two separate jobs:

- `readLocal` reads usage files, transcripts and session files. It doesn't touch the network.
- `fetchLive` asks the live sources for accounts that are due. It skips accounts whose stored reading is less than 5 minutes old. When it finishes, it runs `readLocal` again.

A failed live read shows on its account as a `LiveUsage.Failure` until any newer reading arrives. An account in use is never asked, since its status line keeps its reading fresh, so waiting for the next live read would keep a failure such as an expired login on screen after the login was refreshed.

A slow network request never delays the local numbers. Blocking work, such as waiting on `codex app-server` or on `security` reading the keychain, runs on a dispatch thread. It would otherwise hold one of Swift concurrency's few shared threads, which other tasks need. Only a refresh the user asks for spins the refresh icon. Timer ticks change nothing that is published unless the numbers change, so the views don't redraw for nothing.

⌥⌘A opens `QuickSwitcher`, a floating window for switching from any app. `HotKey` registers the shortcut through Carbon's hot-key API, which needs no accessibility permission.

In the panel, clicking an account asks for confirmation before switching, because a switch changes every terminal's next session. After the first switch, if the shell line is missing, the panel offers to add it and to turn on the status line. Right-click opens **Rename…**, **Log In Again** and **Show in Finder**. Each row's interaction is one `RowFocus` value: confirming, renaming, or none. A row receives everything it can do as one `RowActions` value, so a row only displays and calls back.

## Moving a conversation

`acc continue` finds the newest Claude Code or Codex conversation started in the current folder, in any account. It copies the conversation to the target account, then resumes it there. A Claude Code conversation is a transcript in `projects/<folder slug>/` plus a folder of subagent transcripts beside it. A Codex conversation is one rollout file under `sessions/YYYY/MM/DD/`. opencode keeps conversations in a database, so they can't move.

## Tests

`script/test` runs the unit tests in `Tests/AccCoreTests`, then `Tests/e2e.sh`. The end-to-end script builds a throwaway `HOME` with stub `claude`, `codex` and `opencode` scripts. It then drives the real `acc` binary and the shell functions it generates through setup, switching, `@account`, usage, `continue`, `doctor`, `sync`, rename and removal. The unit tests use the same kind of stub for `codex app-server`. They also include a reply copied from a real Codex.

## Adding a tool

1. Add a case to `Tool` and a `ToolSpec` with its variable, folders and shared items.
2. Add a `<Tool>Support` file for its login status, and for its usage and conversations if it keeps any.
3. Extend the `switch` statements the compiler then points you to. They cover `Runner.authStatus`, `Discovery`, `Identity`, `Sessions`, `Usages` and `LiveUsage`.
4. Add the tool's stub to `Tests/e2e.sh`.

## Known limits

- `TranscriptLog` walks each Claude Code account's whole `projects/` folder once a minute to find new transcripts. An FSEvents stream would replace the walk. Comparing folders' modification times would not, because appending to an existing transcript doesn't change its folder.
- Anthropic's usage endpoint and `codex app-server`'s `account/rateLimits/read` aren't documented. A change on their side shows up as a red message under each affected account.
- Kiro CLI keeps its login in one database that no setting moves, so it can't have separate accounts.

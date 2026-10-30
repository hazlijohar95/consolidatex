# acc

Pick which Claude Code subscription new `claude` sessions use, from the terminal or the menu bar.

Each subscription is a Claude Code config directory (`CLAUDE_CONFIG_DIR`). `acc` keeps a registry of them and which one is current. The zsh `claude` wrapper reads it every time it starts a session, so switching takes effect in every terminal at once. Running sessions keep their account.

## Use

```
acc                 pick (fzf; press 1-9)
acc cto             switch
acc auto            switch to the account with the most quota left
claude              start on the current account
claude @qeel        one session on another account, no switch
acc continue        out of quota? resume this folder's latest conversation on the
                    roomiest other account (or `acc continue hello`)
acc ls              list with last-seen usage (● = current)
acc doctor          check logins, shared config and MCP servers
acc sync            share config and MCP servers from the primary account
acc ui              open the Manage Accounts window
acc add <id> --label <name>   new subscription: creates ~/.claude-<id>, shares config, logs in
acc login <id>      log an account in again
acc rename <id> <label> / acc rm <id>
```

## Manage Accounts window

Open it with `acc ui` or **Manage Accounts…** (⌘,) in the menu bar. In the window you can:

- add a subscription. It suggests a short name, creates the config folder, shares config and opens the browser login.
- rename an account by clicking its name.
- drag rows to reorder them. The order sets the 1–9 shortcuts.
- remove an account. The current and primary accounts can't be removed.
- see each account's health dot (logged in, sharing config) and its 5h and 7d usage bars.
- run **Check** or **Sync Config**.

The window uses the same `AccCore` rules and the same validated store as the CLI, so a change made in either one shows up in the other straight away.

## Usage tracking

Set the status line in the shared `settings.json`:

```json
"statusLine": { "type": "command", "command": "/Users/<you>/.local/bin/acc statusline" }
```

Each session's status line shows its account, its 5-hour and 7-day usage, the model and how full the context is. Once the account passes 90%, it suggests `acc continue <roomiest>`. Each time it renders, it records that account's usage, which is the `rate_limits` data Claude Code already passes to status lines, in `~/.config/acc/usage/<id>.json`. `acc ls`, `acc auto`, `acc continue` and the menu bar all read those files. acc never handles tokens or calls an API. The cost is that an account shows `no data yet` until a session on it has rendered a status line.

## Shared config

The primary account (the one with `configDir: null`) owns `CLAUDE.md`, `settings.json`, `skills`, `agents`, `commands`, `plugins` and `hooks`. Every other account symlinks them. User-scope MCP servers are stored in each account's own `.claude.json`, so `acc sync` copies them from the primary using `claude mcp add-json`. A server that exists only on another account is reported and kept. `--prune` removes it. Add new MCP servers to the primary, then run `acc sync`. OAuth MCP servers still need logging in once per account.

`acc help` has the full list.

## Install and update

```
./script/install            # builds and installs acc, the zsh wrapper and Claude Accounts.app
echo 'source ~/.config/acc/acc.zsh' >> ~/.zshrc   # once
```

To update, run `git pull && ./script/install`. To test, run `./script/test`, which runs the unit tests and then black-box tests of the CLI and wrapper against a stub `claude`.

## Layout

- `Sources/AccCore`: the model. It holds `Registry` (validation and resolving what you type to an account), `RegistryStore` (load, validate, atomic save) and `Claude` (`auth status`, exec). The CLI and the app share it, so there is one parser and one set of rules.
- `Sources/acc`: the CLI.
- `Sources/ClaudeAccounts`: the menu bar app. It watches the registry directory and shows a ⚠︎ with the reason if the registry is invalid.
- `shell/acc.zsh`: the `claude` wrapper. An explicit `CLAUDE_CONFIG_DIR` always wins. If `acc` is missing or the registry is broken, `claude` still starts on the default account and prints a warning.

## Registry

`~/.config/acc/accounts.json` (or `$ACC_HOME/accounts.json`):

```json
{
  "version": 1,
  "current": "cto",
  "accounts": [
    { "id": "team", "label": "Haz (team)", "configDir": null, "email": "…" },
    { "id": "cto",  "label": "CTO", "configDir": "~/.claude-acc4", "email": "…" }
  ]
}
```

`configDir: null` is Claude Code's default `~/.claude`. That account runs with `CLAUDE_CONFIG_DIR` unset, because setting it to `~/.claude` selects a different config file and keychain entry. At most one account can use it. Every write is validated first. An invalid change is refused and the file stays as it was. You can edit the file by hand, and `acc doctor` tells you if the edit broke anything.

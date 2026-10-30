# acc

Pick which Claude Code subscription new `claude` sessions use, from the terminal or the menu bar.

Each subscription is a Claude Code config directory (`CLAUDE_CONFIG_DIR`). `acc` keeps a registry of them and which one is current. The zsh `claude` wrapper reads it every time it starts a session, so switching takes effect in every terminal at once. Running sessions keep their account.

## Use

```
acc                 pick (fzf; press 1-9)
acc cto             switch
claude              start on the current account
claude @qeel        one session on another account, no switch
acc ls              list (● = current)
acc doctor          check every account exists and is logged in
acc add <id> --label <name>   new subscription: creates ~/.claude-<id> and logs in
acc login <id>      log an account in again
acc rename <id> <label> / acc rm <id>
```

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

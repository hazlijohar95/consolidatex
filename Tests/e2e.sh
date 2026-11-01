#!/bin/zsh
# Black-box test of the built `acc` binary and the shell functions it generates, with stub
# claude, codex and opencode binaries and a throwaway HOME. Never touches the real setup.
emulate -L zsh
root=${0:A:h:h}
acc_bin=${ACC_BIN:-$root/.build/debug/acc}
T=$(mktemp -d "${TMPDIR:-/tmp}/acc-e2e.XXXXXX") || exit 1
T=${T:A}  # resolved, as getcwd reports it (/tmp is a symlink on macOS)
trap 'rm -rf $T' EXIT
H=$T/home
mkdir -p $T/bin $H
ln -s $acc_bin $T/bin/acc

# claude: `auth status` → logged in as <folder>@test unless the folder has LOGGED_OUT;
# `mcp add-json/remove --scope user` edit the account's state file like Claude Code does.
cat > $T/bin/claude <<'EOF'
#!/bin/sh
state="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; state="${state:-$HOME/.claude.json}"
if [ "$1 $2" = "auth status" ]; then
  if [ -n "$CLAUDE_CONFIG_DIR" ] && [ -e "$CLAUDE_CONFIG_DIR/LOGGED_OUT" ]; then echo '{"loggedIn":false}'; exit 1; fi
  echo "{\"loggedIn\":true,\"email\":\"$(basename "${CLAUDE_CONFIG_DIR:-default}" | sed 's/^\.claude-//')@test\"}"; exit 0
fi
if [ "$1" = mcp ]; then
  exec /usr/bin/python3 -I - "$state" "$2" "$5" "$6" <<'PY'
import json, os, sys
path, op, name, definition = sys.argv[1:5]
data = json.load(open(path)) if os.path.exists(path) else {}
servers = data.setdefault("mcpServers", {})
if op == "add-json": servers[name] = json.loads(definition)
else: servers.pop(name)
json.dump(data, open(path, "w"))
PY
fi
echo "CFG=${CLAUDE_CONFIG_DIR-<unset>} ARGS=$*"
EOF
# codex: `login status` exits 0 unless the home has LOGGED_OUT; `login` runs $ON_LOGIN (another
# acc acting meanwhile, like the app), then fails with $FAIL_LOGIN or logs the home in.
cat > $T/bin/codex <<'EOF'
#!/bin/sh
home="${CODEX_HOME:-$HOME/.codex}"
if [ "$1 $2" = "login status" ]; then [ -e "$home/LOGGED_OUT" ] && exit 1; exit 0; fi
if [ "$1" = login ]; then
  [ -n "$ON_LOGIN" ] && sh -c "$ON_LOGIN"
  [ -n "$FAIL_LOGIN" ] && exit 1
  rm -f "$home/LOGGED_OUT"; exit 0
fi
echo "CODEX=${CODEX_HOME-<unset>} ARGS=$*"
EOF
# opencode: `auth list --format json` reports one connected provider.
cat > $T/bin/opencode <<'EOF'
#!/bin/sh
case "$*" in *"auth list --format json"*) echo '[{"id":"openai","name":"OpenAI","connections":[{"label":"OpenAI"}]}]'; exit 0;; esac
echo "XDG=${XDG_DATA_HOME-<unset>} ARGS=$*"
EOF
chmod +x $T/bin/claude $T/bin/codex $T/bin/opencode

# Accounts that already exist before acc: a T3 Code setup, sibling folders, defaults.
mkdir -p $H/.claude/skills $H/.claude-cto $H/.codex $H/.codex-side $H/.local/share/opencode $H/.t3/userdata
print rules > $H/.claude/CLAUDE.md
print '{"model": "opus"}' > $H/.claude/settings.json
print '{"mcpServers":{"docs":{"type":"http","url":"https://d"}},"oauthAccount":{"emailAddress":"default@test"}}' > $H/.claude.json
print '{"mcpServers":{"mine":{"type":"http","url":"https://m"}},"oauthAccount":{"emailAddress":"cto@test"}}' > $H/.claude-cto/.claude.json
print 'model = "gpt"' > $H/.codex/config.toml
print '{}' > $H/.codex-side/auth.json
print '{"providerInstances":{"a":{"driver":"claudeAgent","displayName":"Haz (team)","enabled":true}}}' > $H/.t3/userdata/settings.json

export ACC_HOME=$T/acc HOME=$H SHELL=/bin/zsh PATH=$T/bin:/usr/bin:/bin
unset CLAUDE_CONFIG_DIR CODEX_HOME XDG_DATA_HOME

fail=0
check() {
  if [[ $2 == $3 ]]; then print "ok   $1"; else print "FAIL $1\n  got:  [$2]\n  want: [$3]"; fail=1; fi
}
plain() { sed $'s/\e\\[[0-9;]*m//g' }
current() { acc ls $1 | grep '^●' | awk '{print $4}' }
col() { sed 's/^●/ /' | awk "{print $1}" }
sh() { zsh -fc 'eval "$(acc shell-init zsh)"; '"$1" 2>&1 }

# --- first run
check 'nothing yet'                       "$(acc ls 2>&1)" 'acc: no accounts yet (run: acc setup)'
acc setup --yes > $T/setup.txt
check 'setup imports existing accounts'   "$(acc ls | col '$2, $3')" $'claude haz-team\nclaude cto\ncodex codex-default\ncodex side\nopencode opencode-default'
check 'setup keeps T3 names'              "$(acc ls | grep haz-team | col '$4, $5')" 'Haz (team)'
check 'setup records emails'              "$(acc ls | grep ' cto ' | col '$5')" 'cto@test'
check 'setup hooks the shell once'        "$(grep -c 'acc shell-init zsh' $H/.zshrc)" 1
check 'setup turns on the status line'    "$(grep -c 'acc statusline' $H/.claude/settings.json)" 1
check 'setup shares Claude config'        "$(cat $H/.claude-cto/CLAUDE.md)" rules
check 'setup shares Codex config'         "$(cat $H/.codex-side/config.toml)" 'model = "gpt"'
check 'setup mirrors MCP servers'         "$(grep -c '"docs"' $H/.claude-cto/.claude.json)" 1
acc setup --yes > $T/setup2.txt
check 'setup is idempotent'               "$(grep -c 'acc shell-init zsh' $H/.zshrc) $(acc ls | wc -l | tr -d ' ')" '1 5'

# --- switching and launching through the shell functions
check 'claude starts on current (default)' "$(sh 'claude a b')" 'CFG=<unset> ARGS=a b'
acc cto >/dev/null
check 'switch by name'                    "$(sh 'claude')" "CFG=$H/.claude-cto ARGS="
check 'codex keeps its own current'       "$(sh 'codex exec hi')" 'CODEX=<unset> ARGS=exec hi'
acc codex side >/dev/null
check 'switch within a tool'              "$(sh 'codex')" "CODEX=$H/.codex-side ARGS="
check 'switching codex left claude alone' "$(current claude)" cto
acc 3 >/dev/null
check 'switch by position'                "$(current codex)" codex-default
check '@ one-off'                         "$(sh 'codex @side x')" "CODEX=$H/.codex-side ARGS=x"
check '@ does not switch'                 "$(current codex)" codex-default
check '@ resolves within the tool'        "$(sh 'claude @side' ; echo "exit $?")" $'acc: no account matches \'side\' (see: acc ls)\nexit 1'
check 'explicit variable wins'            "$(sh 'CODEX_HOME=/pinned codex')" 'CODEX=/pinned ARGS='
check '@ beats an inherited variable'     "$(sh 'CODEX_HOME=/pinned codex @side x')" "CODEX=$H/.codex-side ARGS=x"
check 'tool arguments pass through as is'  "$(sh 'claude --yes x')" "CFG=$H/.claude-cto ARGS=--yes x"
check 'positions match what ls shows'     "$(acc codex 4 | cut -d: -f2 | awk '{print $1}')" side
acc codex 3 >/dev/null
check 'ambiguous is rejected'             "$(acc default 2>&1; echo "exit $?")" $'acc: \'default\' matches haz-team, codex-default, opencode-default; be more specific\nexit 1'
check 'unknown flag is a usage error'     "$(acc --bogus >/dev/null 2>&1; echo $?)" 2

# --- adding: new folder, shared config, login skipped when already logged in
acc add opencode Mine >/dev/null
check 'add creates the folder'            "$([[ -d $H/.opencode-mine ]] && echo yes)" yes
acc mine >/dev/null
check 'opencode runs standalone on it'    "$(sh 'opencode run hi')" "XDG=$H/.opencode-mine ARGS=--standalone run hi"
check 'opencode default stays plain'      "$(sh 'opencode @opencode-default run')" 'XDG=<unset> ARGS=run'
acc add codex 'Client A' >/dev/null
check 'add links shared codex config'     "$(readlink $H/.codex-client-a/config.toml)" "$H/.codex/config.toml"
check 'add refuses a duplicate'           "$(acc add codex x --id side 2>&1)" "acc: an account with id 'side' already exists"
check 'add refuses an unknown tool'       "$(acc add kiro 2>&1 | head -1)" 'acc: usage: acc add <claude|codex|opencode> [<name>] [--id <id>] [--dir <folder>]'

# --- adding with a login: listed first, so nothing done during the login is lost
mkdir -p $H/.codex-race $H/.codex-flaky; touch $H/.codex-race/LOGGED_OUT $H/.codex-flaky/LOGGED_OUT
ON_LOGIN='acc use side >/dev/null' acc add codex Race >/dev/null
check 'add keeps a switch made during login' "$(current codex)" side
check 'add logs the new account in'       "$([[ -e $H/.codex-race/LOGGED_OUT ]] || echo yes)" yes
check 'failed login keeps the account'    "$(FAIL_LOGIN=1 acc add codex Flaky 2>&1 >/dev/null; echo "exit $?")" $'acc: codex failed: login exited 1\nacc: added \'flaky\', but it isn\'t logged in; try again with: acc login flaky\nexit 1'
check 'it stays listed for the retry'     "$(acc ls codex | grep -c ' flaky ')" 1
check 'acc login retries it'              "$(acc login flaky | tail -1)" 'logged in flaky'

# --- usage, status line, auto
in_status() { print -r -- "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$(( $(date +%s) + 7200 ))}}}" }
check 'status line records and nudges'    "$(in_status 95 | CLAUDE_CONFIG_DIR=$H/.claude-cto acc statusline | plain)" '✳ cto · 5h 95% · Opus  ⇢ acc continue haz-team'
in_status 20 | acc statusline >/dev/null
check 'usage shows in ls'                 "$(acc ls claude | grep ' cto ' | awk -F'  ' '{print $NF}')" '5h 95% · resets in 1h'
mkdir -p $H/.codex/sessions/2026/10/30
print -r -- '{"timestamp":"2026-10-30T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":40,"window_minutes":300,"resets_at":'$(( $(date +%s) + 3600 ))'},"secondary":null}}}' \
  > $H/.codex/sessions/2026/10/30/rollout-2026-10-30T10-00-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl
check 'codex usage read from its sessions' "$(acc ls codex | grep codex-default | awk -F'  ' '{print $NF}')" '5h 40%'
check 'auto picks the roomiest'           "$(acc auto claude | head -1)" 'claude → Claude Code: haz-team  Haz (team)  (default@test)'

# --- continue: newest conversation for this folder moves to the target and resumes there
proj=$T/work; mkdir -p $proj; slug=${proj//[^A-Za-z0-9]/-}
mkdir -p $H/.claude-cto/projects/$slug/s-old
print old > $H/.claude-cto/projects/$slug/s-old.jsonl; touch -t 202601010000 $H/.claude-cto/projects/$slug/s-old.jsonl
print new > $H/.claude-cto/projects/$slug/s-new.jsonl
check 'continue resumes newest on named'  "$(cd $proj && acc continue haz-team 2>/dev/null)" 'CFG=<unset> ARGS=--resume s-new'
check 'continue copied the transcript'    "$(cat $H/.claude/projects/$slug/s-new.jsonl)" new
check 'continue explains itself'          "$(cd $proj && acc continue haz-team 2>&1 >/dev/null)" 'acc: ↪ continuing s-new (last active 1m ago on haz-team) on haz-team'
check 'continue copies the sidecar folder' "$(cd $proj && acc continue haz-team --session s-old >/dev/null 2>&1; [[ -d $H/.claude/projects/$slug/s-old ]] && echo yes)" yes
cuid=0199a1b2-aaaa-7e5f-8a9b-0c1d2e3f4a5b
print -r -- '{"type":"session_meta","payload":{"id":"'$cuid'","cwd":"'$proj'"}}' > $H/.codex/sessions/2026/10/30/rollout-2026-10-30T11-00-00-$cuid.jsonl
check 'continue works for codex'          "$(cd $proj && acc continue side 2>/dev/null)" "CODEX=$H/.codex-side ARGS=resume $cuid"
check 'codex rollout landed in side'      "$([[ -f $H/.codex-side/sessions/2026/10/30/rollout-2026-10-30T11-00-00-$cuid.jsonl ]] && echo yes)" yes
check 'continue refuses opencode'         "$(cd $proj && acc continue mine 2>&1)" 'acc: opencode conversations cannot move between accounts'
check 'continue with nothing to resume'   "$(cd $T && acc continue 2>&1)" "acc: no Claude Code or Codex conversation found for $T"

# --- doctor, sync, rename, rm
check 'doctor only flags the extra MCP'   "$(acc doctor | grep '^[✗!]')" '! cto               has MCP servers haz-team lacks: mine (add them to haz-team to share, or acc sync --prune)'
touch $H/.claude-cto/LOGGED_OUT
check 'doctor flags a logged-out account' "$(acc doctor | grep '^✗'; echo "exit ${pipestatus[1]}")" $'✗ cto               not logged in → acc login cto\nexit 1'
rm $H/.claude-cto/LOGGED_OUT
check 'sync keeps extra MCP servers'      "$(acc sync | grep mine | cut -c1-34)" '! cto: has MCP servers haz-team la'
check 'sync --prune removes them'         "$(acc sync --prune | grep '^cto')" 'cto: MCP mine removed'
check 'sync is idempotent'                "$(acc sync)" 'everything already shares its primary'"'"'s config'
acc rename side Side Gig >/dev/null
acc cto >/dev/null; acc side >/dev/null
check 'rename'                            "$(acc ls codex | grep ' side ' | awk -F'  +' '{print $4}')" 'Side Gig'
check 'rm refuses a current account'      "$(acc rm cto 2>&1; echo "exit $?")" $'acc: \'cto\' is the current Claude Code account; switch to another one first\nexit 2'
check 'rm refuses a primary with others'  "$(acc rm codex-default 2>&1)" "acc: 'codex-default' is the primary Codex account; the others share its config, so remove them first"
acc rm client-a >/dev/null
check 'rm keeps the folder'               "$([[ -d $H/.codex-client-a ]] && echo yes) $(acc ls | grep -c client-a)" 'yes 0'
acc setup --yes >/dev/null
check 'setup leaves removed folders out'  "$(acc ls | grep -c client-a)" 0

check 'report waits for history'         "$(acc report 2>&1)" 'acc: not enough history yet: the Consolidatex menu bar app records usage every 15 minutes while it runs'

# --- resilience
print 'not json' > $ACC_HOME/accounts.json
check 'broken registry still starts tools' "$(sh 'codex z')" $'acc: cannot read '$ACC_HOME$'/accounts.json: not valid JSON\nacc: starting codex on its default account instead (run: acc doctor)\nCODEX=<unset> ARGS=z'
check 'broken registry error is specific' "$(acc ls 2>&1)" "acc: cannot read $ACC_HOME/accounts.json: not valid JSON"
rm $ACC_HOME/accounts.json
check 'no registry: tools run untouched'  "$(sh 'claude q')" 'CFG=<unset> ARGS=q'
check 'fish functions are generated'      "$(acc shell-init fish | grep -c 'command acc launch')" 3

exit $fail

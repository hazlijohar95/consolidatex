#!/bin/zsh
# Black-box test of the built `acc` binary and the zsh `claude` wrapper, using a
# stub claude and a throwaway ACC_HOME. Never touches the real registry.
emulate -L zsh
root=${0:A:h:h}
acc_bin=${ACC_BIN:-$root/.build/debug/acc}
T=$(mktemp -d "${TMPDIR:-/tmp}/acc-e2e.XXXXXX") || exit 1
T=${T:A}  # resolved, as getcwd reports it (/tmp is a symlink on macOS)
trap 'rm -rf $T' EXIT

mkdir -p $T/bin $T/home/.claude-cto $T/home/.claude-hello
ln -s $acc_bin $T/bin/acc
# Stub claude. `auth status` reports logged in as <dirname>@test unless the dir has a
# LOGGED_OUT marker; `mcp add-json/remove --scope user` edit the account's state file
# the way Claude Code does; anything else echoes its account and arguments.
cat > $T/bin/claude <<'EOF'
#!/bin/sh
state="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; state="${state:-$HOME/.claude.json}"
if [ "$1 $2" = "auth status" ]; then
  if [ -n "$CLAUDE_CONFIG_DIR" ] && [ -e "$CLAUDE_CONFIG_DIR/LOGGED_OUT" ]; then echo '{"loggedIn":false}'; exit 1; fi
  echo "{\"loggedIn\":true,\"email\":\"$(basename "${CLAUDE_CONFIG_DIR:-default}")@test\"}"; exit 0
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
chmod +x $T/bin/claude
cat > $T/accounts.json <<EOF
{"version":1,"current":"team","accounts":[
 {"id":"team","label":"Haz (team)","configDir":null,"email":"default@test"},
 {"id":"cto","label":"CTO","configDir":"$T/home/.claude-cto","email":".claude-cto@test"},
 {"id":"hello","label":"Hello","configDir":"$T/home/.claude-hello","email":"stale@test"}
]}
EOF

export ACC_HOME=$T HOME=$T/home PATH=$T/bin:/usr/bin:/bin
unset CLAUDE_CONFIG_DIR ACC_CLAUDE

fail=0
check() {
  if [[ $2 == $3 ]]; then print "ok   $1"; else print "FAIL $1\n  got:  [$2]\n  want: [$3]"; fail=1; fi
}
current() { acc current --json | sed -n 's/.*"id" : "\(.*\)".*/\1/p' }

acc cto >/dev/null;                     check 'switch by name'                 $(current) cto
acc 3 >/dev/null;                       check 'switch by position'             $(current) hello
acc use team >/dev/null;                check 'switch with use'                $(current) team
check 'ambiguous is rejected'           "$(acc h 2>&1; echo "exit $?")"        $'acc: \'h\' matches team, hello; be more specific\nexit 1'
check 'unknown is rejected'             "$(acc nope 2>&1; echo "exit $?")"     $'acc: no account matches \'nope\' (see: acc ls)\nexit 1'
check 'failed switch keeps state'       $(current) team
check 'unknown flag is a usage error'   "$(acc --bogus >/dev/null 2>&1; echo $?)" 2
check 'dir of default is empty'         "$(acc dir)" ''
check 'dir of named'                    "$(acc dir cto)" $T/home/.claude-cto
check 'non-tty bare acc lists'          "$(acc </dev/null | grep '●')" '● 1  team   Haz (team)  default@test      no data yet'
check 'run sets dir'                    "$(acc run cto -- -p hi)" "CFG=$T/home/.claude-cto ARGS=-p hi"
check 'run default drops inherited dir' "$(CLAUDE_CONFIG_DIR=/x acc run team)" 'CFG=<unset> ARGS='

check 'rm current is refused'           "$(acc rm team 2>&1; echo "exit $?")" $'acc: \'team\' is the current account; switch to another one first\nexit 2'
acc rename hello Hello World >/dev/null
check 'rename'                          "$(acc ls | grep hello)" '  3  hello  Hello World  stale@test        no data yet'

check 'doctor flags stale email'        "$(acc doctor | grep hello)" '! hello  logged in as .claude-hello@test, registry says stale@test (run acc doctor --fix to record it)'
acc doctor --fix >/dev/null
check 'doctor --fix records email'      "$(acc ls | grep hello)" '  3  hello  Hello World  .claude-hello@test  no data yet'
touch $T/home/.claude-cto/LOGGED_OUT
check 'doctor fails on logged-out'      "$(acc doctor | grep cto; echo "exit ${pipestatus[1]}")" $'✗ cto    not logged in → acc login cto\nexit 1'
rm $T/home/.claude-cto/LOGGED_OUT

acc add ah --label 'A&H' --dir $T/home/.claude-ah >/dev/null
check 'add creates dir'                 "$([[ -d $T/home/.claude-ah ]] && echo yes)" yes
check 'add registers'                   "$(acc ls | grep ' ah ')" '  4  ah     A&H          .claude-ah@test     no data yet'
check 'add duplicate is refused'        "$(acc add cto 2>&1)" "acc: an account with id 'cto' already exists"
check 'add reserved id is refused'      "$(acc add ls 2>&1)" "acc: 'ls' is not a valid id: use lowercase letters, digits and '-', starting with a letter, and not an acc command"
acc rm ah >/dev/null;                   check 'rm'                             "$(acc ls | grep -c ' ah ')" 0

# statusline: records live usage for the session's account, renders, and nudges when nearly out
in_status() { print -r -- "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$(( $(date +%s) + 7200 ))}}}" }
check 'statusline records + nudges'     "$(in_status 95 | CLAUDE_CONFIG_DIR=$T/home/.claude-cto acc statusline | sed $'s/\e\\[[0-9;]*m//g')" '✳ CTO · 5h 95% · Opus  ⇢ acc continue team'
check 'usage shows in ls'               "$(acc ls | grep ' cto ' | awk -F'  ' '{print $NF}')" '5h 95% · resets in 1h'
in_status 20 | acc statusline >/dev/null
check 'auto picks the roomiest'         "$(acc auto | head -1)" 'claude → team  Haz (team)  (default@test)'
check 'statusline without usage'        "$(print '{}' | CLAUDE_CONFIG_DIR=$T/home/.claude-hello acc statusline | sed $'s/\e\\[[0-9;]*m//g')" '✳ Hello World'
check 'statusline survives garbage'     "$(print 'nope' | acc statusline | sed $'s/\e\\[[0-9;]*m//g')" '✳ Haz (team) · 5h 20%'

# continue: newest transcript for this folder moves to the target account and resumes there
proj=$T/work; mkdir -p $proj; slug=${proj//[^A-Za-z0-9]/-}
mkdir -p $T/home/.claude-cto/projects/$slug/s-old $T/home/.claude/projects/$slug
print old > $T/home/.claude-cto/projects/$slug/s-old.jsonl; touch -t 202601010000 $T/home/.claude-cto/projects/$slug/s-old.jsonl
print new > $T/home/.claude-cto/projects/$slug/s-new.jsonl
check 'continue resumes newest on named' "$(cd $proj && acc continue hello 2>/dev/null)" "CFG=$T/home/.claude-hello ARGS=--resume s-new"
check 'continue copied transcript'       "$(cat $T/home/.claude-hello/projects/$slug/s-new.jsonl)" new
check 'continue explains itself'         "$(cd $proj && acc continue hello 2>$T/err >/dev/null; cut -c1-40 $T/err)" '↪ continuing s-new (last active 1m ago o'
check 'continue picks roomiest by default' "$(cd $proj && acc continue --session s-old 2>/dev/null)" 'CFG=<unset> ARGS=--resume s-old'
check 'continue copies sidecar folder'   "$([[ -d $T/home/.claude/projects/$slug/s-old ]] && echo yes)" yes
check 'continue with nothing to resume'  "$(cd $T && acc continue 2>&1)" "acc: no Claude Code conversation found for $T"

# sync: link shared config and mirror MCP servers from the primary (team)
mkdir -p $T/home/.claude/skills; print rules > $T/home/.claude/CLAUDE.md
print '{"mcpServers":{"docs":{"type":"http","url":"https://d"}}}' > $T/home/.claude.json
print '{"mcpServers":{"mine":{"type":"http","url":"https://m"}}}' > $T/home/.claude-cto/.claude.json
check 'doctor reports drift'            "$(acc doctor | grep '^! cto')" $'! cto    CLAUDE.md is not shared from team → acc sync\n! cto    skills is not shared from team → acc sync\n! cto    missing MCP servers docs → acc sync\n! cto    has MCP servers team lacks: mine (add them to team to share, or acc sync --prune)'
check 'sync links and mirrors'          "$(acc sync | grep '^cto')" 'cto: linked CLAUDE.md, linked skills, MCP docs added'
check 'sync shares the real file'       "$(cat $T/home/.claude-cto/CLAUDE.md)" rules
check 'sync keeps extras by default'    "$(acc sync | grep 'cto.*mine' | cut -c1-30)" '! cto: has MCP servers team la'
check 'sync --prune removes extras'     "$(acc sync --prune | grep '^cto')" 'cto: MCP mine removed'
check 'sync is idempotent'              "$(acc sync)" 'everything already matches team'

W() { zsh -fc "source $root/shell/acc.zsh; $1" 2>&1 }
acc cto >/dev/null
check 'wrapper follows current'         "$(W 'claude a b')" "CFG=$T/home/.claude-cto ARGS=a b"
check 'wrapper @ one-off'               "$(W 'claude @hello x')" "CFG=$T/home/.claude-hello ARGS=x"
check 'wrapper @ does not switch'       $(current) cto
check 'wrapper @ unknown fails'         "$(W 'claude @zzz'; echo "exit $?")" $'acc: no account matches \'zzz\' (see: acc ls)\nexit 1'
check 'wrapper respects pinned dir'     "$(W 'CLAUDE_CONFIG_DIR=/pinned claude')" 'CFG=/pinned ARGS='
acc team >/dev/null
check 'wrapper default account'         "$(W claude)" 'CFG=<unset> ARGS='
print 'not json' > $T/accounts.json
check 'broken registry still starts claude' "$(W 'claude z')" $'acc: cannot read '$T$'/accounts.json: not valid JSON\nacc: starting claude on its default account instead (run: acc doctor)\nCFG=<unset> ARGS=z'
check 'broken registry error is specific'   "$(acc ls 2>&1)" "acc: cannot read $T/accounts.json: not valid JSON"

exit $fail

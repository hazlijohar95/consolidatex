#!/bin/zsh
# Black-box test of the built `acc` binary and the zsh `claude` wrapper, using a
# stub claude and a throwaway ACC_HOME. Never touches the real registry.
emulate -L zsh
root=${0:A:h:h}
acc_bin=${ACC_BIN:-$root/.build/debug/acc}
T=$(mktemp -d "${TMPDIR:-/tmp}/acc-e2e.XXXXXX") || exit 1
trap 'rm -rf $T' EXIT

mkdir -p $T/bin $T/home/.claude-cto $T/home/.claude-hello
ln -s $acc_bin $T/bin/acc
# Stub claude: `auth status` reports logged in as <dirname>@test unless the dir has a LOGGED_OUT marker.
cat > $T/bin/claude <<'EOF'
#!/bin/sh
if [ "$1 $2" = "auth status" ]; then
  if [ -n "$CLAUDE_CONFIG_DIR" ] && [ -e "$CLAUDE_CONFIG_DIR/LOGGED_OUT" ]; then echo '{"loggedIn":false}'; exit 1; fi
  echo "{\"loggedIn\":true,\"email\":\"$(basename "${CLAUDE_CONFIG_DIR:-default}")@test\"}"; exit 0
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

export ACC_HOME=$T PATH=$T/bin:/usr/bin:/bin
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
check 'non-tty bare acc lists'          "$(acc </dev/null | grep '●')" '● 1  team   Haz (team)  default@test'
check 'run sets dir'                    "$(acc run cto -- -p hi)" "CFG=$T/home/.claude-cto ARGS=-p hi"
check 'run default drops inherited dir' "$(CLAUDE_CONFIG_DIR=/x acc run team)" 'CFG=<unset> ARGS='

check 'rm current is refused'           "$(acc rm team 2>&1; echo "exit $?")" $'acc: \'team\' is the current account; switch to another one first\nexit 2'
acc rename hello Hello World >/dev/null
check 'rename'                          "$(acc ls | grep hello)" '  3  hello  Hello World  stale@test'

check 'doctor flags stale email'        "$(acc doctor | grep hello)" '! hello  logged in as .claude-hello@test, registry says stale@test (run acc doctor --fix to record it)'
acc doctor --fix >/dev/null
check 'doctor --fix records email'      "$(acc ls | grep hello)" '  3  hello  Hello World  .claude-hello@test'
touch $T/home/.claude-cto/LOGGED_OUT
check 'doctor fails on logged-out'      "$(acc doctor | grep cto; echo "exit ${pipestatus[1]}")" $'✗ cto    not logged in → acc login cto\nexit 1'
rm $T/home/.claude-cto/LOGGED_OUT

acc add ah --label 'A&H' --dir $T/home/.claude-ah >/dev/null
check 'add creates dir'                 "$([[ -d $T/home/.claude-ah ]] && echo yes)" yes
check 'add registers'                   "$(acc ls | grep ' ah ')" '  4  ah     A&H          .claude-ah@test'
check 'add duplicate is refused'        "$(acc add cto 2>&1)" "acc: an account with id 'cto' already exists"
check 'add reserved id is refused'      "$(acc add ls 2>&1)" "acc: 'ls' is not a valid id: use lowercase letters, digits and '-', starting with a letter, and not an acc command"
acc rm ah >/dev/null;                   check 'rm'                             "$(acc ls | grep -c ' ah ')" 0

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

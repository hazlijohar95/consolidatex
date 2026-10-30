# Sourced from ~/.zshrc (installed to ~/.config/acc/acc.zsh by script/install).
# `claude` starts on the account chosen with `acc`; `claude @cto …` runs one
# session on another account without switching. An explicit CLAUDE_CONFIG_DIR
# always wins, and if acc is missing or broken claude still starts, with a warning.
claude() {
  if [[ $1 == @?* ]]; then
    local ref=${1#@}; shift
    command acc run "$ref" -- "$@"
    return
  fi
  if [[ -n ${CLAUDE_CONFIG_DIR-} ]] || (( ! $+commands[acc] )); then
    command claude "$@"
    return
  fi
  local dir
  if ! dir=$(command acc dir); then
    print -u2 "acc: starting claude on its default account instead (run: acc doctor)"
    command claude "$@"
    return
  fi
  if [[ -n $dir ]]; then
    CLAUDE_CONFIG_DIR=$dir command claude "$@"
  else
    command claude "$@"
  fi
}

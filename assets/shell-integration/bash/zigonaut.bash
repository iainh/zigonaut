# Zigonaut OSC 133/7 integration for interactive Bash 4.4 and newer.
_zigonaut_bootstrap_status=$?
[[ $- == *i* ]] || return 0
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || return 0
[[ ${_ZIGONAUT_BASH_INTEGRATION_LOADED-} ]] && return 0
_ZIGONAUT_BASH_INTEGRATION_LOADED=1
unset ZIGONAUT_BASH_INTEGRATION
unset ZIGONAUT_SHELL_INTEGRATION

_zigonaut_tty_write() { builtin printf '%s' "$1" >/dev/tty 2>/dev/null; }

_zigonaut_osc7() {
  [[ $PWD == /* ]] || return 0
  local LC_ALL=C encoded= char hex i
  for ((i = 0; i < ${#PWD}; i++)); do
    char=${PWD:i:1}
    if [[ $char == [A-Za-z0-9._~/-] ]]; then
      encoded+=$char
    else
      printf -v hex '%02X' "'$char"
      encoded+=%$hex
    fi
  done
  _zigonaut_tty_write $'\e]7;file://localhost'"$encoded"$'\a'
}

_zigonaut_emit_c() { _zigonaut_tty_write $'\e]133;C\a'; }
_zigonaut_capture_status() {
  local command_status=$?
  _zigonaut_command_status=$command_status
  return "$command_status"
}
_zigonaut_prompt() {
  if [[ -v _zigonaut_command_open ]]; then
    _zigonaut_tty_write $'\e]133;D;'"$_zigonaut_command_status"$'\a'
    unset _zigonaut_command_open
  fi
  _zigonaut_osc7
  _zigonaut_tty_write $'\e]133;A\a'

  if [[ $PS1 == "$_zigonaut_decorated_ps1" ]]; then PS1=$_zigonaut_base_ps1; fi
  _zigonaut_base_ps1=$PS1
  _zigonaut_decorated_ps1=$PS1$'\[\e]133;B\a\]'
  PS1=$_zigonaut_decorated_ps1
  return "$_zigonaut_command_status"
}

# Remove the one-shot source command while retaining commands that startup
# files placed before or after it. The launcher uses this exact spelling.
_zigonaut_strip_bootstrap() {
  local value=$1 source_command='builtin source "$ZIGONAUT_BASH_INTEGRATION" 2>/dev/null'
  value=${value//"$source_command"/}
  value=${value#;}; value=${value%;}
  value=${value//;;/;}
  printf '%s' "$value"
}

if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
  _zigonaut_prompt_commands=()
  for _zigonaut_pc in "${PROMPT_COMMAND[@]}"; do
    _zigonaut_pc=$(_zigonaut_strip_bootstrap "$_zigonaut_pc")
    [[ $_zigonaut_pc ]] && _zigonaut_prompt_commands+=("$_zigonaut_pc")
  done
  PROMPT_COMMAND=(_zigonaut_capture_status "${_zigonaut_prompt_commands[@]}" _zigonaut_prompt)
  unset _zigonaut_prompt_commands _zigonaut_pc
else
  PROMPT_COMMAND=$(_zigonaut_strip_bootstrap "${PROMPT_COMMAND-}")
  PROMPT_COMMAND="_zigonaut_capture_status${PROMPT_COMMAND:+;$PROMPT_COMMAND};_zigonaut_prompt"
fi
unset -f _zigonaut_strip_bootstrap

# PS0 is expanded once after a complete command is accepted and before it runs.
# The parameter expansion records that fact in the parent shell; command
# substitution writes C without becoming part of command output or redirection.
PS0='${_zigonaut_command_open:=}$(_zigonaut_emit_c)'"${PS0-}"

# The one-shot bootstrap is already running for the first prompt, so the newly
# installed PROMPT_COMMAND won't be visited until the next prompt.
_zigonaut_command_status=$_zigonaut_bootstrap_status
_zigonaut_prompt

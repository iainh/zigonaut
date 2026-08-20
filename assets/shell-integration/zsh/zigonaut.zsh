# Minimal Zigonaut OSC 133/7 integration for interactive zsh sessions.
[[ -o interactive ]] || return 0
(( ${+_ZIGONAUT_ZSH_INTEGRATION_LOADED} )) && return 0
typeset -g _ZIGONAUT_ZSH_INTEGRATION_LOADED=1
typeset -g _ZIGONAUT_COMMAND_OPEN=0
typeset -g _ZIGONAUT_PS1_BASE=
typeset -g _ZIGONAUT_PS1_DECORATED=
typeset -g _ZIGONAUT_PS2_BASE=
typeset -g _ZIGONAUT_PS2_DECORATED=

function _zigonaut_tty_write {
  builtin print -nr -- "$1" > /dev/tty 2>/dev/null
}

function _zigonaut_osc7 {
  [[ $PWD == /* ]] || return 0
  local LC_ALL=C encoded= byte hex
  local index
  for (( index = 1; index <= ${#PWD}; index++ )); do
    byte=$PWD[index]
    if [[ $byte == [A-Za-z0-9._~/-] ]]; then
      encoded+=$byte
    else
      builtin printf -v hex '%02X' "'$byte"
      encoded+=%$hex
    fi
  done
  _zigonaut_tty_write $'\e]7;file://localhost'${encoded}$'\a'
}

function _zigonaut_decorate_prompts {
  if [[ $PS1 == $_ZIGONAUT_PS1_DECORATED ]]; then
    PS1=$_ZIGONAUT_PS1_BASE
  fi
  if [[ $PS2 == $_ZIGONAUT_PS2_DECORATED ]]; then
    PS2=$_ZIGONAUT_PS2_BASE
  fi

  _ZIGONAUT_PS1_BASE=$PS1
  _ZIGONAUT_PS2_BASE=$PS2
  _ZIGONAUT_PS1_DECORATED=$'%{\e]133;A\a%}'${PS1}$'%{\e]133;B\a%}'
  _ZIGONAUT_PS2_DECORATED=$'%{\e]133;A;k=s\a%}'${PS2}$'%{\e]133;B\a%}'
  PS1=$_ZIGONAUT_PS1_DECORATED
  PS2=$_ZIGONAUT_PS2_DECORATED
}

function _zigonaut_precmd {
  local command_status=$?
  (( $# )) && command_status=$1
  if (( _ZIGONAUT_COMMAND_OPEN )); then
    _zigonaut_tty_write $'\e]133;D;'${command_status}$'\a'
    _ZIGONAUT_COMMAND_OPEN=0
  fi
  _zigonaut_osc7
  _zigonaut_decorate_prompts
}

function _zigonaut_preexec {
  if [[ $PS1 == $_ZIGONAUT_PS1_DECORATED ]]; then
    PS1=$_ZIGONAUT_PS1_BASE
  fi
  if [[ $PS2 == $_ZIGONAUT_PS2_DECORATED ]]; then
    PS2=$_ZIGONAUT_PS2_BASE
  fi
  _zigonaut_tty_write $'\e]133;C\a'
  _ZIGONAUT_COMMAND_OPEN=1
}

# This hook is loaded from .zshenv. Deferring one precmd lets .zshrc and prompt
# frameworks finish, while appending to the hook arrays preserves their hooks.
function _zigonaut_install_hooks {
  local command_status=$?
  precmd_functions=(${precmd_functions:#_zigonaut_install_hooks})
  precmd_functions+=(_zigonaut_precmd)
  preexec_functions+=(_zigonaut_preexec)

  # Perform this prompt's work now; newly appended hooks are not guaranteed to
  # be visited by the current zsh hook iteration.
  _zigonaut_precmd $command_status
}

precmd_functions+=(_zigonaut_install_hooks)

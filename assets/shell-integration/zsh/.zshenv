# Zigonaut's ZDOTDIR trampoline. This file must remain quiet.
typeset -g _zigonaut_zshenv_path=${${(%):-%N}:A}
function _zigonaut_zshenv_trampoline {
  local trampoline_path=$_zigonaut_zshenv_path
  local integration_dir=${trampoline_path:h}
  local startup_status=0
  unset _zigonaut_zshenv_path

  if (( ${+ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR} )); then
    export ZDOTDIR=$ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  unset ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR

  local user_zshenv=${ZDOTDIR:-$HOME}/.zshenv
  if [[ -r $user_zshenv && ${user_zshenv:A} != $trampoline_path ]]; then
    builtin source "$user_zshenv"
    startup_status=$?
  fi

  if [[ -o interactive && -r $integration_dir/zigonaut.zsh ]]; then
    builtin source "$integration_dir/zigonaut.zsh"
  fi
  return $startup_status
}

_zigonaut_zshenv_trampoline
return $?

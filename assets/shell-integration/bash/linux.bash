# Interactive, non-login Bash startup for the Linux frontend (--rcfile).
# Keep the normal user startup file, including scalar or array PROMPT_COMMAND.
if [[ -r ~/.bashrc ]]; then
  builtin source ~/.bashrc
fi

# The bundled integration requires Bash 4.4. Older Bash keeps normal startup.
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  PROMPT_COMMAND=('builtin source "$ZIGONAUT_BASH_INTEGRATION" 2>/dev/null' "${PROMPT_COMMAND[@]}")
else
  unset ZIGONAUT_BASH_INTEGRATION ZIGONAUT_SHELL_INTEGRATION
fi

#!/usr/bin/env bash
set -euo pipefail

sample='Zigonaut text decoration'

printf '\033[2J\033[HText decoration test case\n\n'
printf '  none           %s\n' "$sample"
printf '  single         \033[4m%s\033[24m\n' "$sample"
printf '  double         \033[4:2m%s\033[4:0m\n' "$sample"
printf '  curly          \033[4:3m%s\033[4:0m\n' "$sample"
printf '  dotted         \033[4:4m%s\033[4:0m\n' "$sample"
printf '  dashed         \033[4:5m%s\033[4:0m\n' "$sample"
printf '  strikethrough  \033[9m%s\033[29m\n' "$sample"
printf '  overline       \033[53m%s\033[55m\n' "$sample"
printf '  coloured       \033[58:2:255:95:95;4:3m%s\033[4:0;59m\n' "$sample"
printf '\nPress Enter to exit.'
read -r

# Zigonaut OSC 133/7 integration for interactive fish 2.7 and newer.
status --is-interactive; or return
set -q _ZIGONAUT_FISH_INTEGRATION_LOADED; and return
set -g _ZIGONAUT_FISH_INTEGRATION_LOADED 1
set -e ZIGONAUT_FISH_INTEGRATION
set -e ZIGONAUT_SHELL_INTEGRATION
set -g _zigonaut_command_open 0

function __zigonaut_tty_write
    printf '%b' "$argv[1]" >/dev/tty 2>/dev/null
end

function __zigonaut_osc7
    string match -q '/*' -- "$PWD"; or return
    set -l encoded
    for byte in (printf '%s' "$PWD" | command od -An -v -tx1)
        for hex in (string split ' ' -- (string trim -- "$byte"))
            test -n "$hex"; or continue
            set -l decimal (printf '%d' "0x$hex")
            if test $decimal -ge 45 -a $decimal -le 57; or test $decimal -ge 65 -a $decimal -le 90; or test $decimal -ge 97 -a $decimal -le 122; or test $decimal -eq 95; or test $decimal -eq 126
                set encoded "$encoded"(printf '%b' "\\x$hex")
            else
                set encoded "$encoded%"(string upper -- "$hex")
            end
        end
    end
    __zigonaut_tty_write "\e]7;file://localhost$encoded\a"
end

function __zigonaut_preexec --on-event fish_preexec
    test -n (string trim -- "$argv[1]"); or return
    __zigonaut_tty_write '\e]133;C\a'
    set -g _zigonaut_command_open 1
end

function __zigonaut_postexec --on-event fish_postexec
    set -g _zigonaut_command_status $status
end

function __zigonaut_restore_status
    return $argv[1]
end

if functions -q fish_prompt
    functions -c fish_prompt __zigonaut_original_fish_prompt
else
    function __zigonaut_original_fish_prompt
        printf '%s@%s %s> ' (whoami) (hostname | string split -m1 .)[1] (prompt_pwd)
    end
end

function fish_prompt
    set -l command_status $status
    if test $_zigonaut_command_open -eq 1
        __zigonaut_tty_write "\e]133;D;$_zigonaut_command_status\a"
        set -g _zigonaut_command_open 0
    end
    __zigonaut_osc7
    __zigonaut_tty_write '\e]133;A\a'
    __zigonaut_restore_status $command_status
    __zigonaut_original_fish_prompt
    set -l prompt_status $status
    __zigonaut_tty_write '\e]133;B\a'
    return $prompt_status
end

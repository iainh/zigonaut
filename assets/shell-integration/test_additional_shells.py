#!/usr/bin/env python3
"""PTY checks for fish and non-system Bash shell integration."""

import os
import pathlib
import pty
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent


def read_until(fd: int, needle: bytes, timeout: float = 5.0) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            data.extend(os.read(fd, 65536))
        except OSError:
            break
    if needle not in data:
        raise AssertionError(f"timed out waiting for {needle!r}: {bytes(data)!r}")
    return bytes(data)


def run_shell(helper: pathlib.Path, shell: pathlib.Path, kind: str, bash_array: bool = False,
              linux: bool = False) -> None:
    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        working_directory = home / "initial cwd"
        working_directory.mkdir()
        startup_log = home / "startup.log"
        hook_log = home / "hook.log"
        if kind == "bash":
            prompt_hook = (
                'PROMPT_COMMAND=("$PROMPT_COMMAND" ": user-hook")\n'
                if bash_array
                else 'PROMPT_COMMAND="$PROMPT_COMMAND; : user-hook"\n'
            )
            if linux:
                # Replacing (not appending to) PROMPT_COMMAND is common in .bashrc.
                hook = f"printf hook >> {hook_log}"
                prompt_hook = (f'PROMPT_COMMAND=({shlex.quote(hook)} ": user-hook")\n'
                               if bash_array else f'PROMPT_COMMAND={shlex.quote(hook)}\n')
            (home / (".bashrc" if linux else ".bash_profile")).write_text(
                f"printf profile >> {startup_log!s}\n"
                "PS1='VISIBLE> '\n"
                f"{prompt_hook}"
            )
            if linux:
                (home / ".bash_profile").write_text("echo unexpected-login >> ~/startup.log\n")
        else:
            config = home / ("custom-config/fish" if linux else ".config/fish")
            config.mkdir(parents=True)
            (config / "config.fish").write_text(
                f"printf config >> {startup_log!s}\n"
                "set -g fish_greeting\n"
                "function fish_prompt; printf 'VISIBLE> '; end\n"
            )

        master, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            environment = os.environ.copy()
            environment.update(HOME=str(home), TERM="dumb", ZIGONAUT_TEST_VALUE="preserved ü")
            if linux:
                environment.pop("ZIGONAUT_SHELL_INTEGRATION", None)
                environment["XDG_CONFIG_HOME"] = str(home / "custom-config")
                environment["SHELL"] = str(shell)
                os.chdir(working_directory)
                for standard in range(3):
                    os.dup2(slave, standard)
                os.close(master)
                os.close(slave)
                os.execve(str(helper), [str(helper), "--pty-child"], environment)
            os.dup2(slave, 10)
            os.close(master)
            os.close(slave)
            os.execve(str(helper), [str(helper), str(shell), "", str(ROOT)], environment)
        os.close(slave)

        try:
            startup = read_until(master, b"\x1b]133;B\x07")
            assert b"\x1b]133;A\x07" in startup, repr(startup)
            assert b"\x1b]133;B\x07" in startup, repr(startup)
            assert startup.count(b"\x1b]133;A\x07") == 1, repr(startup)

            if linux:
                os.write(master, b'printf "%s\\n%s\\n" "$PWD" "$ZIGONAUT_TEST_VALUE"\n')
                inherited = read_until(master, b"\x1b]133;B\x07")
                assert f"{working_directory}\r\npreserved ü\r\n".encode() in inherited, repr(inherited)

            os.write(master, b"true\n")
            success = read_until(master, b"\x1b]133;D;0\x07")
            assert success.count(b"\x1b]133;C\x07") == 1, repr(success)

            os.write(master, b"false\n")
            failed = read_until(master, b"\x1b]133;D;1\x07")
            assert failed.count(b"\x1b]133;C\x07") == 1, repr(failed)

            encoded_directory = home / "space ü"
            encoded_directory.mkdir()
            os.write(master, f"cd {shlex.quote(str(encoded_directory))}\n".encode())
            changed = read_until(master, b"space%20%C3%BC\x07")
            assert b"\x1b]133;D;0\x07" in changed, repr(changed)

            output = home / "redirected"
            os.write(master, f"printf payload > {output!s}\n".encode())
            read_until(master, b"\x1b]133;D;0\x07")
            assert output.read_bytes() == b"payload"
            assert startup_log.read_text() == ("profile" if kind == "bash" else "config")
            if linux and kind == "bash":
                assert hook_log.read_text().startswith("hookhook"), "User prompt hook lost"
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(master)
            os.waitpid(pid, 0)


def verify_system_bash_is_unchanged(helper: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        (home / ".bash_profile").write_text("PS1='PLAIN> '\n")
        master, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            environment = os.environ.copy()
            environment.update(HOME=str(home), TERM="dumb")
            os.dup2(slave, 10)
            os.close(master)
            os.close(slave)
            os.execve(str(helper), [str(helper), "/bin/bash", "", str(ROOT)], environment)
        os.close(slave)
        try:
            startup = read_until(master, b"PLAIN> ")
            assert b"\x1b]133;" not in startup, repr(startup)
            os.write(master, b"true\n")
            command = read_until(master, b"PLAIN> ")
            assert b"\x1b]133;" not in command, repr(command)
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(master)
            os.waitpid(pid, 0)


def verify_linux_fallback(helper: pathlib.Path, shell, disabled: bool = False) -> None:
    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        for name in (".bashrc", ".zshrc"):
            (home / name).write_text("PS1='PLAIN> '\n")
        config = home / ".config/fish"
        config.mkdir(parents=True)
        (config / "config.fish").write_text(
            "set -g fish_greeting; function fish_prompt; printf 'PLAIN> '; end\n")
        master, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            environment = os.environ.copy()
            for name in ("SHELL", "ZDOTDIR", "XDG_CONFIG_HOME", "ZIGONAUT_SHELL_INTEGRATION"):
                environment.pop(name, None)
            environment.update(HOME=str(home), TERM="dumb", PS1="PLAIN> ")
            if shell is not None:
                environment["SHELL"] = shell
            if disabled:
                environment["ZIGONAUT_SHELL_INTEGRATION"] = "0"
            os.chdir(home)
            for standard in range(3):
                os.dup2(slave, standard)
            os.close(master)
            os.close(slave)
            os.execve(str(helper), [str(helper), "--pty-child"], environment)
        os.close(slave)
        try:
            startup = read_until(master, b"PLAIN> ")
            assert b"\x1b]133;" not in startup, repr(startup)
            os.write(master, b"printf 'fallback-ok\\n'\n")
            # fish can redraw its prompt before executing the command.
            command = read_until(master, b"fallback-ok\r\n")
            assert b"\x1b]133;" not in command, repr(command)
            assert b"fallback-ok\r\n" in command, repr(command)
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(master)
            os.waitpid(pid, 0)


def main() -> None:
    linux = sys.argv[-1:] == ["--linux"]
    arguments = sys.argv[1:-1] if linux else sys.argv[1:]
    if len(arguments) != 3:
        raise SystemExit("usage: test_additional_shells.py HELPER BASH FISH [--linux]")
    helper, bash, fish = map(lambda value: pathlib.Path(value).resolve(), arguments)
    if linux:
        # Exercise /bin/bash literally too; macOS deliberately excludes it.
        bash = pathlib.Path(arguments[1]).absolute()
        fish = pathlib.Path(arguments[2]).absolute()
    run_shell(helper, bash, "bash", linux=linux)
    run_shell(helper, bash, "bash", bash_array=True, linux=linux)
    run_shell(helper, fish, "fish", linux=linux)
    if linux:
        for shell in ("/bin/sh", None, "relative-shell"):
            verify_linux_fallback(helper, shell)
        for shell in (str(bash), "/bin/zsh", str(fish)):
            verify_linux_fallback(helper, shell, disabled=True)
        with tempfile.TemporaryDirectory() as directory:
            prefix = pathlib.Path(directory) / "relocated space ' ü"
            (prefix / "bin").mkdir(parents=True)
            relocated = prefix / "bin/zigonaut"
            shutil.copy2(helper, relocated)
            resources = prefix / "share/zigonaut/shell-integration"
            shutil.copytree(helper.parent.parent / "share/zigonaut/shell-integration", resources)
            run_shell(relocated, bash, "bash", linux=True)
            run_shell(relocated, fish, "fish", linux=True)
            subprocess.run([sys.executable, str(ROOT / "test_shell_integration.py"),
                            str(relocated), "--linux"], check=True)
            shutil.rmtree(resources)
            for shell in (str(bash), "/bin/zsh", str(fish)):
                verify_linux_fallback(relocated, shell)
        print("Linux relocation, missing resources, opt-out and unsupported-shell fallbacks passed")
    else:
        verify_system_bash_is_unchanged(helper)
    print("Bash and fish shell-integration PTY tests passed")


if __name__ == "__main__":
    main()

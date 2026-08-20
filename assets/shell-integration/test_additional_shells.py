#!/usr/bin/env python3
"""PTY checks for fish and non-system Bash shell integration."""

import os
import pathlib
import pty
import select
import shlex
import signal
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


def run_shell(helper: pathlib.Path, shell: pathlib.Path, kind: str, bash_array: bool = False) -> None:
    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        startup_log = home / "startup.log"
        if kind == "bash":
            prompt_hook = (
                'PROMPT_COMMAND=("$PROMPT_COMMAND" ": user-hook")\n'
                if bash_array
                else 'PROMPT_COMMAND="$PROMPT_COMMAND; : user-hook"\n'
            )
            (home / ".bash_profile").write_text(
                f"printf profile >> {startup_log!s}\n"
                "PS1='VISIBLE> '\n"
                f"{prompt_hook}"
            )
        else:
            config = home / ".config/fish"
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
            environment.update(HOME=str(home), TERM="dumb")
            os.dup2(slave, 10)
            os.close(master)
            os.close(slave)
            os.execve(str(helper), [str(helper), str(shell), "", str(ROOT)], environment)
        os.close(slave)

        try:
            startup = read_until(master, b"VISIBLE> ")
            assert b"\x1b]133;A\x07" in startup, repr(startup)
            assert b"\x1b]133;B\x07" in startup, repr(startup)

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


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: test_additional_shells.py HELPER BASH FISH")
    helper, bash, fish = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:])
    run_shell(helper, bash, "bash")
    run_shell(helper, bash, "bash", bash_array=True)
    run_shell(helper, fish, "fish")
    verify_system_bash_is_unchanged(helper)
    print("Bash and fish shell-integration PTY tests passed")


if __name__ == "__main__":
    main()

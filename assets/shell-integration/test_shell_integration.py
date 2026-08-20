#!/usr/bin/env python3
"""Standalone PTY checks for the bundled zsh integration."""

import os
import pathlib
import pty
import select
import signal
import shlex
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent
ZSH = ROOT / "zsh"
HELPER = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None


def read_until(fd: int, needle: bytes, timeout: float = 5.0) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data.extend(os.read(fd, 65536))
            except OSError:
                break
    if needle not in data:
        raise AssertionError(f"timed out waiting for {needle!r}: {bytes(data)!r}")
    return bytes(data)


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        temp = pathlib.Path(directory)
        zdot = temp / "config"
        zdot.mkdir()
        log = temp / "startup.log"
        for name in (".zshenv", ".zprofile", ".zshrc", ".zlogin"):
            extra = "PS1='VISIBLE> '; PS2='CONT> '" if name == ".zshrc" else ""
            (zdot / name).write_text(f"print -r -- {name} >> {log!s}; {extra}\n")

        fd, slave = pty.openpty()
        pid = os.fork()
        if pid == 0:
            env = os.environ.copy()
            env.update(
                HOME=str(temp),
                ZDOTDIR=str(zdot),
                TERM="xterm-256color",
            )
            if HELPER:
                os.dup2(slave, 10)
                os.close(fd)
                os.close(slave)
                os.execve(str(HELPER), [str(HELPER), "/bin/zsh", "", str(ZSH)], env)
            os.close(fd)
            for standard in range(3):
                os.dup2(slave, standard)
            os.close(slave)
            env.update(
                ZDOTDIR=str(ZSH),
                ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR=str(zdot),
            )
            os.execve("/bin/zsh", ["zsh", "-l"], env)
        os.close(slave)

        try:
            startup = read_until(fd, b"VISIBLE> ")
            assert b"\x1b]133;A\x07VISIBLE> \x1b]133;B\x07" in startup, repr(startup)
            assert startup.count(b"\x1b]133;A\x07") == 1

            os.write(fd, b"print -r -- $ZDOTDIR; true\n")
            success = read_until(fd, b"VISIBLE> ")
            assert str(zdot).encode() in success
            assert b"\x1b]133;C\x07" in success and b"\x1b]133;D;0\x07" in success

            os.write(fd, b"false\n")
            failed = read_until(fd, b"VISIBLE> ")
            assert b"\x1b]133;D;1\x07" in failed

            encoded_directory = temp / "space ü"
            encoded_directory.mkdir()
            os.write(fd, f"cd {shlex.quote(str(encoded_directory))} && true\n".encode())
            changed = read_until(fd, b"VISIBLE> ")
            assert b"space%20%C3%BC\x07" in changed, repr(changed)

            output = temp / "redirected"
            os.write(fd, f"print payload > {output!s}\n".encode())
            read_until(fd, b"VISIBLE> ")
            assert output.read_bytes() == b"payload\n"

            os.write(fd, f"source {ZSH / 'zigonaut.zsh'}; true\n".encode())
            duplicate = read_until(fd, b"VISIBLE> ")
            assert duplicate.count(b"\x1b]133;C\x07") == 1
            assert log.read_text().splitlines() == [
                ".zshenv", ".zprofile", ".zshrc", ".zlogin"
            ]
        finally:
            os.kill(pid, signal.SIGHUP)
            os.close(fd)
            os.waitpid(pid, 0)

    print("zsh shell-integration PTY tests passed")


if __name__ == "__main__":
    main()

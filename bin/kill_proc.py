#!/usr/bin/env python3
"""Kill a user process by pid. Refuses pid <= 1."""

from __future__ import annotations

import os
import signal
import sys


def kill_pid(pid: int) -> int:
    if pid <= 1:
        print("refusing pid <= 1", file=sys.stderr)
        return 2
    try:
        os.kill(pid, signal.SIGKILL)
        return 0
    except ProcessLookupError:
        print(f"no such process {pid}", file=sys.stderr)
        return 1
    except PermissionError:
        print(f"permission denied for pid {pid}", file=sys.stderr)
        return 1


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print("usage: kill-proc <pid>", file=sys.stderr)
        return 2
    try:
        pid = int(args[0])
    except ValueError:
        print("pid must be an integer", file=sys.stderr)
        return 2
    return kill_pid(pid)


if __name__ == "__main__":
    raise SystemExit(main())

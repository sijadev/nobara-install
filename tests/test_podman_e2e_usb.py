#!/usr/bin/env python3
"""Podman E2E test entrypoint.

Separates test orchestration (Python) from execution logic (Shell in tools/).
"""

from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str]) -> int:
    return subprocess.run(cmd, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true", help="Run real E2E test")
    args = parser.parse_args()

    if not args.run:
        print("[podman-e2e] skipped (nutze --run fuer echten E2E-Lauf)")
        return 0

    if shutil.which("podman") is None:
        print("[podman-e2e] skipped (podman nicht gefunden)")
        return 0

    project_dir = Path(__file__).resolve().parent.parent
    inner_runner = "/src/tools/podman_e2e_inner.sh"

    if platform.system() == "Darwin":
        _ = run(["podman", "machine", "start"])
        print("[podman-e2e] starte E2E via podman machine (rootful container)...")
        cmd = (
            "sudo podman run --rm --privileged "
            f"-v '{project_dir}:/src:Z' fedora:latest /bin/bash {inner_runner}"
        )
        return run(["podman", "machine", "ssh", cmd])

    print("[podman-e2e] starte E2E-Container...")
    return run(
        [
            "podman",
            "run",
            "--rm",
            "--privileged",
            "-v",
            f"{project_dir}:/src:Z",
            "fedora:latest",
            "/bin/bash",
            inner_runner,
        ]
    )


if __name__ == "__main__":
    sys.exit(main())

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
import time
from pathlib import Path


def run(cmd: list[str]) -> int:
    return subprocess.run(cmd, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true", help="Run real E2E test")
    parser.add_argument(
        "--keep-on-fail",
        action="store_true",
        help="Keep podman container for debugging when run fails",
    )
    args = parser.parse_args()

    if not args.run:
        print("[podman-e2e] skipped (nutze --run fuer echten E2E-Lauf)")
        return 0

    if shutil.which("podman") is None:
        print("[podman-e2e] skipped (podman nicht gefunden)")
        return 0

    project_dir = Path(__file__).resolve().parent.parent
    inner_runner = "/src/tools/podman_e2e_inner.sh"
    debug_name = f"fedora-install-e2e-{int(time.time())}"

    if args.keep_on_fail:
        print(f"[podman-e2e] debug mode aktiv (container name: {debug_name})")

    if platform.system() == "Darwin":
        _ = run(["podman", "machine", "start"])
        print("[podman-e2e] starte E2E via podman machine (rootful container)...")
        if not args.keep_on_fail:
            cmd = (
                "sudo podman run --rm --privileged "
                f"-v '{project_dir}:/src:Z' fedora:latest /bin/bash {inner_runner}"
            )
            return run(["podman", "machine", "ssh", cmd])

        cmd = (
            f"sudo podman run --name {debug_name} --privileged -v '{project_dir}:/src:Z' fedora:latest /bin/bash {inner_runner}; "
            "rc=$?; "
            "if [ $rc -eq 0 ]; then "
            f"  sudo podman rm -f {debug_name} >/dev/null; "
            "else "
            f"  echo '[podman-e2e] FAIL - Container behalten: {debug_name}'; "
            f"  echo '[podman-e2e] Debug: podman machine ssh \"sudo podman logs {debug_name}\"'; "
            f"  echo '[podman-e2e] Debug: podman machine ssh \"sudo podman start -ai {debug_name}\"'; "
            "fi; "
            "exit $rc"
        )
        return run(["podman", "machine", "ssh", cmd])

    print("[podman-e2e] starte E2E-Container...")
    if not args.keep_on_fail:
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

    rc = run(
        [
            "podman",
            "run",
            "--name",
            debug_name,
            "--privileged",
            "-v",
            f"{project_dir}:/src:Z",
            "fedora:latest",
            "/bin/bash",
            inner_runner,
        ]
    )
    if rc == 0:
        _ = run(["podman", "rm", "-f", debug_name])
        return 0

    print(f"[podman-e2e] FAIL - Container behalten: {debug_name}")
    print(f"[podman-e2e] Debug: podman logs {debug_name}")
    print(f"[podman-e2e] Debug: podman start -ai {debug_name}")
    print(
        "[podman-e2e] Debug: "
        f"podman machine ssh \"sudo podman logs {debug_name}; "
        f"echo '--- journal (last 200) ---'; sudo journalctl -n 200 --no-pager\""
    )
    return rc


if __name__ == "__main__":
    sys.exit(main())

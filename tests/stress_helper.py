#!/usr/bin/env python3
"""Launch the helper many times and fail on stderr or non-JSON output.

This is deliberately a process-startup test, not a hardware stress test. It
does the same thing the shell does: `python -I helper/thermal_power.py`, one
process at a time, and validates every result. It is used to catch interpreter
shutdown noise such as the CPython 3.14/PyGObject race seen in other GTK-based
helpers; this helper is stdlib-only, but the test keeps it that way.

    python3 -I tests/stress_helper.py --runs 320
    python3 -I tests/stress_helper.py --runs 320 --mock preview
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "helper" / "thermal_power.py"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=320)
    parser.add_argument("--mock", default="")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    if args.runs < 300:
        parser.error("--runs must be at least 300")

    command = [sys.executable, "-I", str(HELPER)]
    if args.mock:
        command.extend(["--mock", args.mock])

    failures = []
    started = time.monotonic()
    worst = 0.0
    for index in range(args.runs):
        run_started = time.monotonic()
        try:
            result = subprocess.run(
                command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, timeout=args.timeout,
            )
        except subprocess.TimeoutExpired:
            failures.append((index, "timeout"))
            continue
        elapsed = time.monotonic() - run_started
        worst = max(worst, elapsed)
        if result.returncode != 0:
            failures.append((index, "exit " + str(result.returncode)))
        if result.stderr.strip():
            failures.append((index, "stderr: " + result.stderr.strip()[:200]))
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            failures.append((index, "invalid JSON: " + str(error)))
            continue
        if document.get("schema") != 1:
            failures.append((index, "bad schema"))
        if args.mock and document.get("mock") != args.mock:
            failures.append((index, "wrong mock name"))
        if index == 0:
            print("first sample: cpu=" + str(document.get("cpu", {}).get("package_c")) +
                  " battery=" + str(document.get("battery", {}).get("present")))

    total = time.monotonic() - started
    print("runs=" + str(args.runs) +
          " total=" + format(total, ".2f") + "s" +
          " mean=" + format(total / args.runs * 1000, ".1f") + "ms" +
          " worst=" + format(worst * 1000, ".1f") + "ms" +
          " python=" + sys.version.split()[0])
    if failures:
        print("FAILURES: " + str(len(failures)))
        for index, message in failures[:20]:
            print("  run " + str(index) + ": " + message)
        return 1
    print("all runs exited 0 with empty stderr and valid schema-1 JSON")
    return 0


if __name__ == "__main__":
    sys.exit(main())

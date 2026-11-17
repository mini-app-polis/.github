"""Fail when a job in this repository's workflows has no timeout.

Every job that runs steps must declare ``timeout-minutes``; without one a
hung step holds a runner for GitHub's six-hour limit. A job that calls a
reusable workflow (``uses:``) cannot take a timeout, so the jobs inside
that workflow carry it instead.

Usage: python3 scripts/check-workflow-timeouts.py [workflows dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


def missing_timeouts(workflows: Path) -> list[str]:
    missing: list[str] = []
    for path in sorted(workflows.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text()) or {}
        for name, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job:
                continue
            if "timeout-minutes" not in job:
                missing.append(f"{path.name}: job {name!r} has no timeout-minutes")
    return missing


def main() -> int:
    workflows = Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows")
    missing = missing_timeouts(workflows)
    for line in missing:
        print(f"::error::{line}")
    if missing:
        return 1
    print(f"Every job in {workflows} declares timeout-minutes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

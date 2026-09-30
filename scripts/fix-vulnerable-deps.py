#!/usr/bin/env python3
"""Clear the dependency audit's findings by re-locking the vulnerable packages.

The fleet's dependency audit (security.yml, SEC-003) finds what has gone
vulnerable but never fixes it. The fix is almost always the same: re-lock the
flagged package at a version that carries the fix. Twice on 2026-09-30 that
was done by hand in api-kaianolevine-com, once for urllib3 and once for
virtualenv, and every other repo on the same lock needed the same two bumps.
This is that step, done by dependency-fix.yml on a schedule instead.

It audits exactly what the gate audits: the same `uv export`, the same lines
filtered out, pip-audit with --strict. Dependabot security updates cannot
stand in for this — they act on GitHub's advisory database, which lags the
PyPA advisories pip-audit reads and may never carry some of them, and they
open against the default branch rather than `dev`.

For each flagged package the target is the smallest version that fixes
every advisory against it, so a security fix is the smallest jump that
clears the audit rather than a surprise major. If that exact version will
not resolve against the rest of the lock, the package is upgraded as far as
the declared ranges allow instead, and the re-audit decides whether that
was enough.

A package is not a fleet library's to fix first. A library's own uv.lock
never reaches the repos that use it; each repo resolves the transitive
package in its own lock, within the ranges the library declares. Only a
library that caps the package below the fix blocks this, and the re-audit
reports it as a finding that could not be cleared.

Usage: fix-vulnerable-deps.py <repo-dir>

Writes to $GITHUB_OUTPUT (when set):
  changed    true if uv.lock was modified
  remaining  number of advisories the re-audit still reports
and writes three files to the current directory:
  fix-subject.txt  the commit and pull-request title
  fix-body.md      what was bumped, for which advisories
  fix-report.md    the full outcome, including anything left unfixed

Exit status is 0 whether or not anything was fixed; the workflow decides
what an unfixed finding means. A non-zero exit is an audit that could not
run at all.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from packaging.version import InvalidVersion, Version

# The two kinds of line security.yml removes before auditing: the project
# itself, and dependencies from git or a URL (the fleet's own unpublished
# libraries, audited in their own repos). Kept identical to that workflow's
# sed expression so the two audits cannot disagree about scope.
EXCLUDED = re.compile(r"^\s*(-e\s|\.\s*$)|@\s+(git|file|https?)\+?")


def run(
    cmd: list[str], cwd: Path, check: bool = True
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=True)


def audit(repo: Path) -> list[dict]:
    """Return pip-audit's dependency list, as security.yml would audit it."""
    exported = run(
        [
            "uv",
            "export",
            "--format",
            "requirements-txt",
            "--no-hashes",
            "--all-extras",
            "--quiet",
        ],
        repo,
    ).stdout
    kept = [line for line in exported.splitlines() if not EXCLUDED.search(line)]
    if not any(line.strip() and not line.lstrip().startswith("#") for line in kept):
        raise SystemExit("Resolved 0 dependencies; refusing to report a vacuous pass.")

    with tempfile.TemporaryDirectory() as tmp:
        req = Path(tmp, "requirements.txt")
        out = Path(tmp, "audit.json")
        req.write_text("\n".join(kept) + "\n")
        # pip-audit exits 1 both for findings and for a failed run, so the
        # JSON report, not the exit status, says which happened. Three
        # attempts, as in security.yml: PyPI's JSON API times out on
        # occasion, and a real finding is reported the same way each time.
        for attempt in (1, 2, 3):
            out.unlink(missing_ok=True)
            proc = run(
                [
                    "pip-audit",
                    "--requirement",
                    str(req),
                    "--strict",
                    "--timeout",
                    "60",
                    "--format",
                    "json",
                    "--output",
                    str(out),
                ],
                repo,
                check=False,
            )
            try:
                return json.loads(out.read_text())["dependencies"]
            except (FileNotFoundError, json.JSONDecodeError, KeyError):
                print(
                    f"pip-audit attempt {attempt} did not produce a report:\n{proc.stderr}",
                    file=sys.stderr,
                )
                if attempt < 3:
                    time.sleep(20)
    raise SystemExit("pip-audit could not complete an audit in three attempts.")


def findings(deps: list[dict]) -> dict[str, dict]:
    return {d["name"]: d for d in deps if d.get("vulns")}


def target_version(current: str, vulns: list[dict]) -> Version | None:
    """Smallest version above `current` that fixes every advisory, or None."""
    now = Version(current)
    needed: list[Version] = []
    for vuln in vulns:
        fixes = []
        for raw in vuln.get("fix_versions", []):
            try:
                v = Version(raw)
            except InvalidVersion:
                continue
            if v > now:
                fixes.append(v)
        if not fixes:
            return None
        # Advisories can list a fix per release line (1.26.19, 2.2.2); the
        # nearest one above the current version is the one to move to.
        needed.append(min(fixes))
    return max(needed)


def locked_versions(repo: Path) -> dict[str, str]:
    text = (repo / "uv.lock").read_text()
    return dict(
        re.findall(r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', text)
    )


def main() -> None:
    repo = Path(sys.argv[1]).resolve()
    before_lock = (repo / "uv.lock").read_text()
    before = findings(audit(repo))

    attempted: list[str] = []
    for name, dep in sorted(before.items()):
        target = target_version(dep["version"], dep["vulns"])
        if target is None:
            continue
        pinned = run(
            ["uv", "lock", "--upgrade-package", f"{name}=={target}"], repo, check=False
        )
        if pinned.returncode != 0:
            run(["uv", "lock", "--upgrade-package", name], repo)
        attempted.append(name)

    after = findings(audit(repo)) if attempted else before
    changed = (repo / "uv.lock").read_text() != before_lock
    locked = locked_versions(repo)

    fixed = [n for n in before if n not in after]
    remaining = sum(len(d["vulns"]) for d in after.values())

    subject = (
        "fix(deps): patch vulnerable dependencies (" + ", ".join(sorted(fixed)) + ")"
    )
    body_lines = ["Re-locked to clear the dependency audit (SEC-003):", ""]
    for name in sorted(fixed):
        ids = ", ".join(v["id"] for v in before[name]["vulns"])
        body_lines.append(
            f"- {name} {before[name]['version']} → {locked.get(name, '?')} for {ids}"
        )
    body_lines += ["", "Opened by dependency-fix.yml in mini-app-polis/.github."]

    report = ["## Dependency fix", ""]
    if not before:
        report.append("The audit is clean; nothing to fix.")
    else:
        report += (
            body_lines[2:-2] if fixed else ["Nothing could be fixed by re-locking."]
        )
    if after:
        report += ["", "### Not cleared", ""]
        for name, dep in sorted(after.items()):
            for v in dep["vulns"]:
                fixes = ", ".join(v.get("fix_versions") or []) or "none published"
                report.append(
                    f"- {name} {dep['version']}: {v['id']} (fixed in: {fixes})"
                )
        report += [
            "",
            (
                "Either no fixed version exists yet, or a declared range — this repo's or a "
                "dependency's — keeps the lock below it. Find the cap with `uv tree --invert "
                "--package <name>`."
            ),
        ]

    Path("fix-subject.txt").write_text(subject + "\n")
    Path("fix-body.md").write_text("\n".join(body_lines) + "\n")
    Path("fix-report.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))

    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"changed={'true' if changed and fixed else 'false'}\n")
            fh.write(f"remaining={remaining}\n")

    # A lock that changed without clearing anything is not worth a pull
    # request; put it back so the workflow sees an untouched tree.
    if changed and not fixed:
        (repo / "uv.lock").write_text(before_lock)


if __name__ == "__main__":
    main()

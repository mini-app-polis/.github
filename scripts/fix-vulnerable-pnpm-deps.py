#!/usr/bin/env python3
"""Clear the dependency audit's findings in a pnpm repository.

The pnpm counterpart of fix-vulnerable-deps.py, run by dependency-fix.yml for
a repository with a pnpm-lock.yaml on `dev`. It audits what the gate audits
(security.yml's Node dependency audit): osv-scanner over the repository's
lockfiles, which honours an osv-scanner.toml beside a lockfile.

pnpm has no `--upgrade-package` that takes a version, so a fix is written
into package.json and the lock is re-resolved from it:

- a direct dependency, resolved at the flagged version, has its declared
  range raised to the fixed version, keeping its `^`, `~` or exact form;
- anything else gets a `pnpm.overrides` entry for the locked version's
  release line (`name@7`, or `name@>=0.24.0 <0.25.0` when the fix is past
  the line) that moves it to `^fixed`. An override already under the same
  key, or under the bare name, is raised instead, so two overrides never
  compete for one package.

The version written is the smallest one that clears every advisory against
the locked version, as in the uv path, so a range is never raised further
than the fix needs; pnpm then resolves the newest release inside it. The
lock is re-resolved with `pnpm install --lockfile-only`, which keeps every
other resolution that still satisfies its range, and audited again. An edit the lock will not resolve,
or that does not clear its advisory, is dropped, so package.json only ever
gains entries that did something.

Usage: fix-vulnerable-pnpm-deps.py <repo-dir>

Writes the same outputs and files as fix-vulnerable-deps.py:
  $GITHUB_OUTPUT  changed (package.json or pnpm-lock.yaml modified and
                  something cleared), remaining (advisories still reported)
  fix-subject.txt, fix-body.md, fix-report.md in the current directory

Exit status is 0 whether or not anything was fixed; a non-zero exit is an
audit or a re-lock that could not run at all.
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

import yaml

LOCK = "pnpm-lock.yaml"
MANIFEST = "package.json"
DIRECT_SECTIONS = ("dependencies", "devDependencies", "optionalDependencies")


# --- npm versions -----------------------------------------------------------

_SEMVER = re.compile(
    r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$"
)


def vkey(version: str) -> tuple:
    """Sort key for an npm version; a release sorts after its prereleases."""
    m = _SEMVER.match(version.strip())
    if not m:
        raise ValueError(f"not a version: {version!r}")
    major, minor, patch = (int(m[i] or 0) for i in (1, 2, 3))
    if m[4] is None:
        pre: tuple = ((1,),)
    else:
        pre = tuple(
            (0, int(p), "") if p.isdigit() else (1, 0, p) for p in m[4].split(".")
        )
        pre = ((0,),) + pre
    return (major, minor, patch, pre)


def is_version(text: str) -> bool:
    return bool(_SEMVER.match(text.strip()))


# --- the audit --------------------------------------------------------------


def run(
    cmd: list[str], cwd: Path, check: bool = True
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=True)


def audit(repo: Path) -> dict[tuple[str, str], list[dict]]:
    """(name, version) -> its OSV vulnerability records, as security.yml scans."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp, "osv.json")
        # osv-scanner exits 0 for a clean scan and 1 for findings; anything
        # else is a scan that did not complete. Three attempts, as the
        # Python audit does: OSV.dev can fail a request, and a real finding
        # is reported the same way each time.
        for attempt in (1, 2, 3):
            out.unlink(missing_ok=True)
            proc = run(
                [
                    "osv-scanner",
                    "scan",
                    "source",
                    "--recursive",
                    "--format",
                    "json",
                    "--output-file",
                    str(out),
                    "./",
                ],
                repo,
                check=False,
            )
            if proc.returncode in (0, 1):
                try:
                    results = json.loads(out.read_text()).get("results") or []
                    break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
            print(
                f"osv-scanner attempt {attempt} did not produce a report "
                f"(exit {proc.returncode}):\n{proc.stderr}",
                file=sys.stderr,
            )
            if attempt < 3:
                time.sleep(20)
        else:
            raise SystemExit("osv-scanner could not complete a scan in three attempts.")

    found: dict[tuple[str, str], list[dict]] = {}
    for result in results:
        for entry in result.get("packages") or []:
            pkg = entry.get("package") or {}
            vulns = entry.get("vulnerabilities") or []
            if pkg.get("ecosystem") != "npm" or not vulns:
                continue
            # One advisory is often several records (a GHSA and its CVE);
            # osv-scanner groups them, and a group is one finding.
            groups = entry.get("groups") or [{"ids": [v["id"]]} for v in vulns]
            by_id = {v["id"]: v for v in vulns}
            records = found.setdefault((pkg["name"], pkg["version"]), [])
            for group in groups:
                ids = [i for i in group.get("ids", []) if i in by_id]
                if ids:
                    records.append({"ids": ids, "records": [by_id[i] for i in ids]})
    return found


def advisory_id(finding: dict) -> str:
    ids = finding["ids"]
    return next((i for i in ids if i.startswith("GHSA-")), ids[0])


def fix_range(name: str, version: str, record: dict) -> tuple[str, str] | None:
    """(introduced, fixed) of the affected range holding `version`, or None."""
    current = vkey(version)
    for affected in record.get("affected") or []:
        pkg = affected.get("package") or {}
        if pkg.get("ecosystem") != "npm" or pkg.get("name") != name:
            continue
        for rng in affected.get("ranges") or []:
            if rng.get("type") not in ("SEMVER", "ECOSYSTEM"):
                continue
            introduced = None
            for event in rng.get("events") or []:
                if "introduced" in event:
                    introduced = event["introduced"]
                    continue
                if introduced is None:
                    continue
                low = (0, 0, 0, ((1,),)) if introduced == "0" else vkey(introduced)
                if "fixed" in event:
                    if low <= current < vkey(event["fixed"]):
                        return introduced, event["fixed"]
                    introduced = None
                elif "last_affected" in event:
                    if low <= current <= vkey(event["last_affected"]):
                        return None
                    introduced = None
            if introduced is not None:
                low = (0, 0, 0, ((1,),)) if introduced == "0" else vkey(introduced)
                if low <= current:
                    return None
    return None


def target(name: str, version: str, findings: list[dict]) -> str | None:
    """Smallest version above `version` that clears every finding, or None."""
    fixes: list[str] = []
    for finding in findings:
        candidates = [
            r[1] for rec in finding["records"] if (r := fix_range(name, version, rec))
        ]
        if not candidates:
            return None
        fixes.append(min(candidates, key=vkey))
    return max(fixes, key=vkey)


def selector(name: str, version: str, fixed: str) -> str:
    """The override key for `version`'s release line.

    pnpm applies `name@<range>` to a dependency only when the range that
    dependency asks for is a subset of `<range>`. Dependents ask for `^` and
    `~` ranges within a release line (a major, or a minor below 1.0), so the
    key is that whole line when the fix is inside it (`name@7`,
    `name@0.24`), and the line up to the fix when the fix is past it
    (`name@>=0.24.0 <0.25.0`).
    """
    major, minor = vkey(version)[:2]
    line, start, end = (
        (f"{major}", f"{major}.0.0", (major + 1, 0))
        if major
        else (f"0.{minor}", f"0.{minor}.0", (0, minor + 1))
    )
    if vkey(fixed)[:2] < end:
        return f"{name}@{line}"
    return f"{name}@>={start} <{fixed}"


# --- the manifest and lock --------------------------------------------------


def direct_versions(repo: Path) -> dict[str, str]:
    """The root importer's direct dependencies, at their locked versions."""
    lock = yaml.safe_load((repo / LOCK).read_text()) or {}
    root = (lock.get("importers") or {}).get(".") or {}
    versions: dict[str, str] = {}
    for section in DIRECT_SECTIONS:
        for name, spec in (root.get(section) or {}).items():
            versions[name] = str(spec.get("version", "")).split("(")[0]
    return versions


def locked_versions(repo: Path) -> dict[str, list[str]]:
    lock = yaml.safe_load((repo / LOCK).read_text()) or {}
    versions: dict[str, list[str]] = {}
    for key in lock.get("packages") or {}:
        name, _, version = str(key).rpartition("@")
        versions.setdefault(name, []).append(version)
    return {n: sorted(set(vs), key=vkey) for n, vs in versions.items()}


def bump_spec(spec: str, fixed: str) -> str | None:
    """`spec` raised to `fixed`, in the same form, or None if it has no simple form."""
    m = re.fullmatch(r"([~^]?)(\S+)", spec.strip())
    if not m or not is_version(m[2]):
        return None
    return f"{m[1]}{fixed}"


class Edit:
    """One change to package.json that should clear one package's findings."""

    def __init__(
        self,
        name: str,
        pairs: list[tuple[str, str]],
        fixed: str,
        section: str | None,
        key: str,
        value: str,
    ) -> None:
        self.name, self.pairs, self.fixed = name, pairs, fixed
        self.section, self.key, self.value = section, key, value

    def apply(self, manifest: dict) -> None:
        if self.section:
            manifest[self.section][self.key] = self.value
        else:
            manifest.setdefault("pnpm", {}).setdefault("overrides", {})[self.key] = (
                self.value
            )

    def describe(self, original: dict) -> str:
        if self.section:
            was = original[self.section][self.key]
            return f"`{self.section}` `{self.key}`: `{was}` → `{self.value}`"
        return f'override `"{self.key}": "{self.value}"`'


def plan(
    repo: Path, manifest: dict, before: dict[tuple[str, str], list[dict]]
) -> tuple[list[Edit], list[str]]:
    direct = direct_versions(repo)
    overrides = (manifest.get("pnpm") or {}).get("overrides") or {}
    edits: dict[str, Edit] = {}
    skipped: list[str] = []
    for (name, version), found in sorted(before.items()):
        fixed = target(name, version, found)
        if fixed is None:
            skipped.append(f"{name} {version}: no fixed version is published")
            continue
        section = next(
            (s for s in DIRECT_SECTIONS if name in (manifest.get(s) or {})), None
        )
        if section and direct.get(name) == version:
            spec = bump_spec(manifest[section][name], fixed)
            if spec is None:
                skipped.append(
                    f"{name} {version}: declared as `{manifest[section][name]}`, "
                    "which has no simple range to raise"
                )
                continue
            edit = Edit(name, [(name, version)], fixed, section, name, spec)
        else:
            key = name if name in overrides else selector(name, version, fixed)
            edit = Edit(name, [(name, version)], fixed, None, key, f"^{fixed}")
        ident = f"{edit.section}:{edit.key}"
        if ident in edits:
            prior = edits[ident]
            prior.pairs += edit.pairs
            if vkey(fixed) > vkey(prior.fixed):
                prior.fixed, prior.value = fixed, edit.value
        else:
            edits[ident] = edit
    return list(edits.values()), skipped


def write_manifest(repo: Path, original_text: str, edits: list[Edit]) -> None:
    manifest = json.loads(original_text)
    for edit in edits:
        edit.apply(manifest)
    indent = re.search(r'\n([ \t]+)"', original_text)
    text = json.dumps(manifest, indent=indent[1] if indent else 2, ensure_ascii=False)
    (repo / MANIFEST).write_text(text + "\n")


def relock(repo: Path) -> subprocess.CompletedProcess[str]:
    # CI makes --frozen-lockfile pnpm's default; this run is the re-lock.
    return run(
        [
            "pnpm",
            "install",
            "--lockfile-only",
            "--ignore-scripts",
            "--no-frozen-lockfile",
        ],
        repo,
        check=False,
    )


def restore(repo: Path, manifest_text: str, lock_text: str) -> None:
    (repo / MANIFEST).write_text(manifest_text)
    (repo / LOCK).write_text(lock_text)


def main() -> None:
    repo = Path(sys.argv[1]).resolve()
    manifest_text = (repo / MANIFEST).read_text()
    lock_text = (repo / LOCK).read_text()
    original = json.loads(manifest_text)
    before = audit(repo)
    edits, skipped = plan(repo, original, before)

    # Each edit is kept only if the lock still resolves with it.
    kept: list[Edit] = []
    for edit in edits:
        write_manifest(repo, manifest_text, kept + [edit])
        if relock(repo).returncode == 0:
            kept.append(edit)
        else:
            skipped.append(f"{edit.name}: {edit.describe(original)} does not resolve")
    restore(repo, manifest_text, lock_text)
    if kept:
        write_manifest(repo, manifest_text, kept)
        relock(repo).check_returncode()

    after = audit(repo) if kept else before
    # Then only if it cleared what it was for.
    cleared = [e for e in kept if not any(p in after for p in e.pairs)]
    if len(cleared) != len(kept):
        for edit in kept:
            if edit not in cleared:
                skipped.append(
                    f"{edit.name}: {edit.describe(original)} resolves, "
                    "but does not clear the advisory"
                )
        restore(repo, manifest_text, lock_text)
        if cleared:
            write_manifest(repo, manifest_text, cleared)
            relock(repo).check_returncode()
            after = audit(repo)
        else:
            after = before

    changed = (repo / MANIFEST).read_text() != manifest_text or (
        repo / LOCK
    ).read_text() != lock_text
    locked = locked_versions(repo) if cleared else {}
    remaining = sum(len(f) for f in after.values())
    fixed_names = sorted({e.name for e in cleared})

    subject = (
        "fix(deps): patch vulnerable dependencies (" + ", ".join(fixed_names) + ")"
    )
    body_lines = ["Re-locked to clear the dependency audit (SEC-003):", ""]
    for edit in sorted(cleared, key=lambda e: e.name):
        was = ", ".join(sorted({v for _, v in edit.pairs}, key=vkey))
        now = ", ".join(locked.get(edit.name, [])) or "?"
        ids = ", ".join(sorted({advisory_id(f) for p in edit.pairs for f in before[p]}))
        body_lines.append(
            f"- {edit.name} {was} → {now} for {ids}, by {edit.describe(original)}"
        )
    body_lines += ["", "Opened by dependency-fix.yml in mini-app-polis/.github."]

    report = ["## Dependency fix", ""]
    if not before:
        report.append("The audit is clean; nothing to fix.")
    else:
        report += (
            body_lines[2:-2] if cleared else ["Nothing could be fixed by re-locking."]
        )
    if after:
        report += ["", "### Not cleared", ""]
        for (name, version), found in sorted(after.items()):
            for finding in found:
                report.append(f"- {name} {version}: {advisory_id(finding)}")
        if skipped:
            report += [""] + [f"- {s}" for s in skipped]
        report += [
            "",
            (
                "Either no fixed version exists yet, or a declared range — this repo's or a "
                "dependency's — keeps the lock below it. Find what pulls it in with "
                "`pnpm why <name>`."
            ),
        ]

    Path("fix-subject.txt").write_text(subject + "\n")
    Path("fix-body.md").write_text("\n".join(body_lines) + "\n")
    Path("fix-report.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))

    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"changed={'true' if changed and cleared else 'false'}\n")
            fh.write(f"remaining={remaining}\n")


if __name__ == "__main__":
    main()

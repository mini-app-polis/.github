#!/usr/bin/env python3
"""Move the fleet onto a new release of one of its own libraries.

commons-update.yml runs this in three places:

  resolve <package> [<version>]
      Before anything is checked out. Without a version, takes the latest
      PyPI reports. Then waits until PyPI's simple index — the API uv reads
      — lists a file for that version. `uv publish` returns when the upload
      is accepted, and the index can lag it by a minute or more; a
      consumer re-locked inside that window resolves the previous release
      and the update silently does nothing.

  consumes <package> <uv.lock | ->
      During discovery. Exits 0 when the lock resolves the package from a
      registry. The package's own repository locks itself as an editable
      source, so it never counts as its own consumer.

  bump <repo-dir> <package> <version> [--branch-lock <file>]
      Per consumer. Re-locks that one package at that version
      (`uv lock --upgrade-package <package>==<version>`), then checks the
      lock changed the way a one-package bump should: the package's own
      entry, packages the new release adds or drops, and versions the new
      release's own ranges move. A rewrite of anything else — the lock's
      header, or an unrelated package's markers or sources at the same
      version, which a different uv can produce — fails rather than riding
      along in a `fix(deps)` pull request nobody reads closely. Then
      `uv lock --check`.

      --branch-lock is the uv.lock on the update branch, when there is one,
      so a slower run for an older release never force-pushes over a pull
      request that already carries a newer one.

Writes to $GITHUB_OUTPUT (when set): for resolve, `package` and `version`;
for bump, `changed` (true when uv.lock was modified), `status` and
`close_stale` (true when an open pull request from the update branch is no
longer needed: dev already has this version or newer, and the branch has
nothing newer than dev). bump also writes commons-subject.txt,
commons-body.md and commons-report.md to the current directory.

bump statuses: bumped, current (already at the version), newer (dev is
past it), superseded (the update branch is past it), absent (the lock does
not resolve the package), blocked (the version will not resolve against
this repository's declared ranges — a major outside `<N`, say; reported as
a warning, since it needs a person to widen a range, not a re-lock).

Exit status is non-zero only for something that should turn the job red:
bad arguments, an index that never served the version, a lock rewrite
outside the package, or a lock that fails --check.

Stdlib only, Python 3.11+ (tomllib). Versions are compared as dotted
integers, which is all semantic-release produces here.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import tomllib

PYPI = os.environ.get("PYPI_URL", "https://pypi.org")
VERSION_RE = re.compile(r"^\d+(\.\d+)*$")
NAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$")


def normalize(name: str) -> str:
    """PEP 503 name normalization, as uv.lock writes names."""
    if not NAME_RE.match(name):
        raise SystemExit(f"Not a package name: {name!r}")
    return re.sub(r"[-_.]+", "-", name).lower()


def vkey(version: str) -> tuple[int, ...]:
    if not VERSION_RE.match(version):
        raise SystemExit(f"Not a plain dotted version: {version!r}")
    parts = [int(p) for p in version.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def output(**values: str) -> None:
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.writelines(f"{k}={v}\n" for k, v in values.items())


def fetch_json(url: str, accept: str = "application/json") -> dict | None:
    req = urllib.request.Request(
        url, headers={"Accept": accept, "Cache-Control": "no-cache"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"{url}: HTTP {e.code}", file=sys.stderr)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"{url}: {e}", file=sys.stderr)
    return None


# --- resolve -----------------------------------------------------------------


def served(package: str, version: str) -> bool:
    """True when the simple index lists a non-yanked file for the version."""
    index = fetch_json(
        f"{PYPI}/simple/{package}/", accept="application/vnd.pypi.simple.v1+json"
    )
    if not index:
        return False
    stem = package.replace("-", "_")
    for f in index.get("files", []):
        name = f.get("filename", "").lower()
        # sdist: <name>-<ver>.tar.gz; wheel: <name>-<ver>-<tags>.whl
        if f.get("yanked"):
            continue
        if name.startswith((f"{stem}-{version}-", f"{stem}-{version}.tar.")):
            return True
    return False


def cmd_resolve(args: argparse.Namespace) -> int:
    package = normalize(args.package)
    version = args.version.strip()
    if not version:
        info = fetch_json(f"{PYPI}/pypi/{package}/json")
        if not info:
            print(f"::error::PyPI has no project {package}.")
            return 1
        version = info["info"]["version"]
        print(f"No version given; PyPI's latest {package} is {version}.")
    vkey(version)

    deadline = time.monotonic() + args.timeout
    while not served(package, version):
        if time.monotonic() >= deadline:
            print(
                f"::error::PyPI's simple index still lists no file for {package} "
                f"{version} after {args.timeout}s. If the release's upload failed, "
                "there is nothing to update; otherwise run this again by hand."
            )
            return 1
        print(f"{package} {version} not on the simple index yet; waiting.")
        time.sleep(args.interval)
    print(f"PyPI serves {package} {version}.")
    output(package=package, version=version)
    return 0


# --- consumes ----------------------------------------------------------------


def registry_versions(lock: dict, package: str) -> list[str]:
    return [
        p["version"]
        for p in lock.get("package", [])
        if p.get("name") == package and "registry" in p.get("source", {})
    ]


def cmd_consumes(args: argparse.Namespace) -> int:
    package = normalize(args.package)
    text = sys.stdin.read() if args.lock == "-" else Path(args.lock).read_text()
    try:
        lock = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return 1
    return 0 if registry_versions(lock, package) else 1


# --- bump --------------------------------------------------------------------


def by_name(lock: dict) -> dict[str, list[str]]:
    """Each package name's entries, as canonical JSON, for comparison."""
    out: dict[str, list[str]] = {}
    for p in lock.get("package", []):
        out.setdefault(p["name"], []).append(json.dumps(p, sort_keys=True))
    return {k: sorted(v) for k, v in out.items()}


def versions_of(lock: dict, name: str) -> list[str]:
    return sorted(
        {p.get("version", "?") for p in lock.get("package", []) if p["name"] == name}
    )


def lock_changes(
    before: dict, after: dict, package: str
) -> tuple[list[str], list[str]]:
    """(expected side effects to report, rewrites that should not happen)."""
    effects: list[str] = []
    problems: list[str] = []

    head_b = {k: v for k, v in before.items() if k != "package"}
    head_a = {k: v for k, v in after.items() if k != "package"}
    for key in sorted(set(head_b) | set(head_a)):
        if head_b.get(key) != head_a.get(key):
            problems.append(f"the lock's top-level `{key}` changed")

    pb, pa = by_name(before), by_name(after)
    for name in sorted(set(pb) | set(pa)):
        if name == package or pb.get(name) == pa.get(name):
            continue
        if name not in pb:
            effects.append(f"{name} {', '.join(versions_of(after, name))} added")
        elif name not in pa:
            effects.append(f"{name} {', '.join(versions_of(before, name))} removed")
        elif versions_of(before, name) != versions_of(after, name):
            effects.append(
                f"{name} {', '.join(versions_of(before, name))} → "
                f"{', '.join(versions_of(after, name))}"
            )
        else:
            problems.append(
                f"{name} {', '.join(versions_of(after, name))} was rewritten "
                "at the same version (markers, sources or metadata)"
            )
    return effects, problems


def uv(args: list[str], repo: Path) -> subprocess.CompletedProcess[str]:
    print("+ uv " + " ".join(args), file=sys.stderr)
    return subprocess.run(
        ["uv", *args], cwd=repo, text=True, capture_output=True, check=False
    )


def cmd_bump(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    package = normalize(args.package)
    version = args.version
    target = vkey(version)
    trigger = os.environ.get("TRIGGER", "").strip() or "A manual run."
    lock_path = repo / "uv.lock"
    before_text = lock_path.read_text()
    before = tomllib.loads(before_text)

    report = [f"## {package} {version}", ""]
    status, changed, close_stale = "", False, False
    exit_code = 0
    subject = f"fix(deps): bump {package} to {version}"
    body: list[str] = []

    current = registry_versions(before, package)
    branch_versions: list[str] = []
    if args.branch_lock and Path(args.branch_lock).is_file():
        try:
            branch_versions = registry_versions(
                tomllib.loads(Path(args.branch_lock).read_text()), package
            )
        except tomllib.TOMLDecodeError:
            branch_versions = []
    branch_top = max((vkey(v) for v in branch_versions), default=None)

    if not current:
        status = "absent"
        report.append(f"`dev`'s uv.lock does not resolve {package} from PyPI.")
    else:
        dev_top = max(vkey(v) for v in current)
        shown = ", ".join(current)
        if dev_top >= target:
            status = "current" if dev_top == target else "newer"
            report.append(f"`dev` is already at {package} {shown}; nothing to do.")
            close_stale = branch_top is not None and branch_top <= dev_top
        elif branch_top is not None and branch_top > target:
            status = "superseded"
            report.append(
                f"The update branch already carries {package} "
                f"{', '.join(branch_versions)}, newer than {version}; leaving it."
            )
        else:
            pin = f"{package}=={version}"
            for attempt in range(1, args.attempts + 1):
                proc = uv(["lock", "--upgrade-package", pin], repo)
                # uv wraps its messages to the terminal width.
                unserved = f"no version of {pin}" in " ".join(proc.stderr.split())
                if proc.returncode == 0:
                    break
                # The index was confirmed before this job started, but each
                # runner reaches PyPI's CDN on its own; give a stale edge a
                # moment. Any other resolution failure will not improve.
                if not unserved or attempt == args.attempts:
                    break
                print(f"uv sees no {pin} yet (attempt {attempt}); retrying.")
                time.sleep(args.retry_wait)

            if proc.returncode != 0 and unserved:
                lock_path.write_text(before_text)
                status = "unserved"
                exit_code = 1
                report += [
                    f"uv could not find {pin} on PyPI after {args.attempts} attempts:",
                    "",
                    "```",
                    proc.stderr.strip(),
                    "```",
                ]
                print(f"::error::uv could not find {pin} on PyPI.")
            elif proc.returncode != 0:
                lock_path.write_text(before_text)
                status = "blocked"
                report += [
                    (
                        f"{pin} does not resolve against this repository's "
                        "declared ranges, so it is not bumped. A release outside "
                        "a declared range (a new major) needs the range widened "
                        "in pyproject.toml by hand."
                    ),
                    "",
                    "```",
                    proc.stderr.strip(),
                    "```",
                ]
                print(
                    f"::warning::{pin} does not resolve against this repository's "
                    "declared ranges; not bumped. See the job summary."
                )
            else:
                after_text = lock_path.read_text()
                after = tomllib.loads(after_text)
                effects, problems = lock_changes(before, after, package)
                check = uv(["lock", "--check"], repo)
                if check.returncode != 0:
                    problems.append(
                        "`uv lock --check` fails on the new lock:\n\n```\n"
                        + check.stderr.strip()
                        + "\n```"
                    )
                if problems:
                    lock_path.write_text(before_text)
                    status = "rewrite"
                    exit_code = 1
                    report += [
                        (
                            f"Re-locking {pin} changed more than {package}, "
                            "so nothing is proposed:"
                        ),
                        "",
                        *[f"- {p}" for p in problems],
                        "",
                        (
                            "This is usually a uv version that writes the lock "
                            "differently from the one that last wrote it. "
                            "Re-lock `dev` with the current uv on its own first."
                        ),
                    ]
                    print(
                        f"::error::Re-locking {pin} rewrote more than {package}; "
                        "see the job summary."
                    )
                elif after_text == before_text:
                    status = "current"
                    report.append("uv left the lock unchanged.")
                else:
                    status, changed = "bumped", True
                    body = [
                        f"Bumps {package} {shown} → {version} in uv.lock.",
                        "",
                    ]
                    if effects:
                        body += [
                            "The new release's own dependencies also moved:",
                            "",
                            *[f"- {e}" for e in effects],
                            "",
                        ]
                    body += [
                        f"Triggered by: {trigger}",
                        "",
                        "Opened by commons-update.yml in mini-app-polis/.github.",
                    ]
                    report += body[:-2]

    Path("commons-subject.txt").write_text(subject + "\n")
    Path("commons-body.md").write_text("\n".join(body) + "\n")
    Path("commons-report.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))
    output(
        changed="true" if changed else "false",
        status=status,
        close_stale="true" if close_stale else "false",
    )
    return exit_code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("resolve")
    r.add_argument("package")
    r.add_argument("version", nargs="?", default="")
    r.add_argument("--timeout", type=int, default=900)
    r.add_argument("--interval", type=int, default=20)
    r.set_defaults(func=cmd_resolve)

    c = sub.add_parser("consumes")
    c.add_argument("package")
    c.add_argument("lock")
    c.set_defaults(func=cmd_consumes)

    b = sub.add_parser("bump")
    b.add_argument("repo")
    b.add_argument("package")
    b.add_argument("version")
    b.add_argument("--branch-lock", default="")
    b.add_argument("--attempts", type=int, default=4)
    b.add_argument("--retry-wait", type=int, default=30)
    b.set_defaults(func=cmd_bump)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

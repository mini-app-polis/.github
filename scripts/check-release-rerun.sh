#!/usr/bin/env bash
# Prove that running the release stage again on a released commit releases
# nothing, with the fleet's locked semantic-release, against a fixture.
#
# The fixture is copied into a throwaway git repository whose only remote is
# a bare repository beside it, so nothing here can reach GitHub, a registry
# or a fleet repository. semantic-release only ever runs with --dry-run, and
# the fixture's .releaserc lists no plugin that publishes. The one tag this
# makes is the scratch repository's own, standing in for the release the
# first run said it would cut.
#
#   1. On the fixture's first commit, a dry run says what it would release.
#   2. That release is recorded as semantic-release records one: a v* tag.
#   3. A second dry run on the same commit must find nothing to release, and
#      the remote must still hold that one tag.
#
# Step 1 is what keeps step 3 from passing vacuously: a run that cannot see a
# release at all would also report nothing.
#
# Usage: scripts/check-release-rerun.sh <fixture dir> <release tooling dir>
#   The tooling dir is .github/actions/semantic-release after `npm ci` there.
set -euo pipefail

fixture="$(cd "$1" && pwd)"
tooling="$(cd "$2" && pwd)"
semantic_release="${tooling}/node_modules/.bin/semantic-release"
[ -x "${semantic_release}" ] || { echo "::error::${semantic_release} not found: run npm ci in ${tooling} first."; exit 1; }
[ -f "${fixture}/.releaserc.json" ] || { echo "::error::${fixture} has no .releaserc.json."; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
git init --quiet --bare --initial-branch=main "${scratch}/origin.git"
mkdir "${scratch}/repo"
# Only the fixture's own files: not the .venv, caches or coverage data a test
# run beside it leaves behind.
(cd "${fixture}" && git ls-files -z --cached --others --exclude-standard . \
  | tar -cf - --null -T - | tar -xf - -C "${scratch}/repo")
cd "${scratch}/repo"
git init --quiet --initial-branch=main
git config user.name "fixture"
git config user.email "fixture@invalid"
git config commit.gpgsign false
git config tag.gpgsign false
git add --all
git commit --quiet --message "feat: the fixture's first release"
git remote add origin "file://${scratch}/origin.git"
git push --quiet origin main

# The run must not take the job's GitHub context for its own: as a pull
# request it would stop before analysing anything, and any token in reach is
# one it has no use for. Without them it reads the branch from git, as it
# does on a workstation.
release() {
  env -u CI -u GITHUB_ACTIONS -u GITHUB_EVENT_NAME -u GITHUB_REF \
      -u GITHUB_HEAD_REF -u GITHUB_BASE_REF -u GITHUB_TOKEN -u GH_TOKEN \
      "${semantic_release}" --dry-run --no-ci 2>&1 | tee "$1"
}

echo "::group::first run on an unreleased commit"
release "${scratch}/first.log"
echo "::endgroup::"
if ! grep -q "the next release version is 1.0.0" "${scratch}/first.log"; then
  echo "::error::The first dry run did not find the release it should have."
  exit 1
fi

git tag v1.0.0
git push --quiet origin v1.0.0

echo "::group::second run on the same commit, now released"
release "${scratch}/second.log"
echo "::endgroup::"
if ! grep -q "Found git tag v1.0.0" "${scratch}/second.log"; then
  echo "::error::The second dry run did not see the release already on this commit."
  exit 1
fi
if grep -qi "next release version is" "${scratch}/second.log" \
   || ! grep -q "There are no relevant changes, so no new version is released." "${scratch}/second.log"; then
  echo "::error::Running the release again on a released commit would release again."
  exit 1
fi
tags="$(git ls-remote --tags origin | wc -l)"
if [ "${tags}" -ne 1 ]; then
  echo "::error::The remote holds ${tags} tags after the second run; it should hold the one release."
  exit 1
fi
echo "A second release run on a released commit releases nothing."

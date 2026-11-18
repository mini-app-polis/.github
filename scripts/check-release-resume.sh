#!/usr/bin/env bash
# Prove that re-running the release stage after it stopped partway finishes
# the release it had cut, with exactly one tag and one release commit, and
# that each finished release is left alone by the run after it.
#
# What the release action does on a re-run is decided by release-state.sh
# and its git half done by finish-release.sh, both in the action's
# directory; this runs those two scripts as the action runs them. The
# GitHub release is the one piece made through the GitHub API, which cannot
# run here: the proof stops at release-state.sh asking for it, with
# GITHUB_RELEASE_EXISTS set as GitHub would answer.
#
# As in check-release-rerun.sh, the fixture is copied into a scratch
# repository whose only remote is a bare repository beside it, so nothing
# here reaches GitHub, a registry or a fleet repository. The release commits
# and tags a stopped release leaves behind are made with git, as
# @semantic-release/git and semantic-release make them; semantic-release
# itself runs only with --dry-run, to show what the next push would release.
#
#   1. Release commit pushed, no tag. While it is untagged, a release of a
#      later commit refuses. The re-run finds the release commit on top of
#      its commit, tags it, and the later release then counts from it.
#   2. Tag pushed, GitHub release missing. The re-run asks for the GitHub
#      release and for nothing else.
#   3. Tag pushed, major tag not moved. The re-run moves it; a re-run of an
#      older release leaves it where it is.
#   4. The reconciler's ref finishes the release it names, from any branch,
#      and only a vX.Y.Z tag on main.
#   5. A release on any branch but main refuses; a dry run does not.
#
# Usage: scripts/check-release-resume.sh <fixture dir> <release tooling dir>
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
origin="file://${scratch}/origin.git"

fail() {
  echo "::error::$*"
  exit 1
}

configure() {
  git config user.name "fixture"
  git config user.email "fixture@invalid"
  git config commit.gpgsign false
  git config tag.gpgsign false
}

mkdir "${scratch}/repo"
(cd "${fixture}" && git ls-files -z --cached --others --exclude-standard . \
  | tar -cf - --null -T - | tar -xf - -C "${scratch}/repo")
cd "${scratch}/repo"
git init --quiet --initial-branch=main
configure
git add --all
git commit --quiet --message "feat: the fixture's first release"
git remote add origin "${origin}"
git push --quiet origin main
first="$(git rev-parse HEAD)"

# A run's checkout: a fresh clone at the run's commit, with the release
# branch and every tag fetched, as the action fetches them.
checkout() {
  local dir="${scratch}/run-$1" commit="$2"
  rm -rf "${dir}"
  git clone --quiet "${origin}" "${dir}"
  cd "${dir}"
  configure
  git fetch --quiet --force --tags origin "+refs/heads/main:refs/remotes/origin/main"
  git checkout --quiet -B main "${commit}"
}

# release-state.sh as the action runs it on a push to main, with any extra
# environment given as NAME=value arguments. Its output goes to state.out.
state() {
  local rc=0
  env -u TARGET_REF -u DRY_RUN -u GITHUB_RELEASE_EXISTS -u MAJOR_TAGS \
    GITHUB_REF=refs/heads/main "$@" bash "${tooling}/release-state.sh" > "${scratch}/state.out" || rc=$?
  cat "${scratch}/state.out"
  return "${rc}"
}

# One key of the last state() output.
get() {
  sed -n "s/^$1=//p" "${scratch}/state.out"
}

expect() {
  local key="$1" want="$2" got
  got="$(get "${key}")"
  [ "${got}" = "${want}" ] || fail "${key} is '${got}', expected '${want}'."
}

refuses() {
  if state "$@" 2>"${scratch}/state.err"; then
    fail "release-state.sh ran where it should refuse ($*)."
  fi
  cat "${scratch}/state.err"
}

finish() {
  TAG="$(get tag)" VERSION="$(get version)" SHA="$(get sha)" \
    CREATE_TAG="$(get create-tag)" MOVE_MAJOR_TAG="$(get move-major-tag)" \
    bash "${tooling}/finish-release.sh"
}

# The release commit @semantic-release/git pushes: CHANGELOG and the notes
# in the message body.
release_commit() {
  echo "## $1" >> CHANGELOG.md
  git add CHANGELOG.md
  git commit --quiet --message "chore(release): $1 [skip ci]" --message "* notes for $1"
}

remote_tags() {
  git ls-remote --tags --refs "${origin}" | sed 's|.*refs/tags/||' | sort | tr '\n' ' '
}

remote_tag_commit() {
  git ls-remote --tags --refs "${origin}" "refs/tags/$1" | cut -f1
}

release_commits() {
  git fetch --quiet origin main
  git log FETCH_HEAD --format=%s | grep -c "^chore(release): $1 " || true
}

dry_release() {
  env -u CI -u GITHUB_ACTIONS -u GITHUB_EVENT_NAME -u GITHUB_REF \
      -u GITHUB_HEAD_REF -u GITHUB_BASE_REF -u GITHUB_TOKEN -u GH_TOKEN \
      "${semantic_release}" --dry-run --no-ci > "$1" 2>&1 || { cat "$1"; fail "semantic-release --dry-run failed."; }
}

echo "::group::0. an unreleased commit is released as usual"
checkout 0 "${first}"
state
expect state release
echo "::endgroup::"

echo "::group::1. release commit pushed, no tag"
# The first run got as far as @semantic-release/git's push, then stopped
# before the tag.
cd "${scratch}/repo"
release_commit 1.0.0
git push --quiet origin main
release1="$(git rev-parse HEAD)"
# Meanwhile main moves on.
echo "second" > second.txt
git add second.txt
git commit --quiet --message "feat: a second feature"
git push --quiet origin main
second="$(git rev-parse HEAD)"

checkout 1a "${second}"
echo "A release of a later commit, while 1.0.0 is untagged:"
refuses

checkout 1b "${first}"
state
expect state finish
expect tag v1.0.0
expect sha "${release1}"
expect create-tag true
expect release-commit true
expect create-github-release unknown
expect move-major-tag false
finish
[ "$(remote_tag_commit v1.0.0)" = "${release1}" ] || fail "v1.0.0 is not on the release commit."
[ "$(remote_tags)" = "v1.0.0 " ] || fail "The remote holds tags '$(remote_tags)'; it should hold v1.0.0 only."

checkout 1c "${first}"
state
expect state finish
expect create-tag false
finish
[ "$(remote_tags)" = "v1.0.0 " ] || fail "A second re-run changed the tags: '$(remote_tags)'."
[ "$(release_commits 1.0.0)" -eq 1 ] || fail "main holds $(release_commits 1.0.0) release commits for 1.0.0."

checkout 1d "${second}"
state
expect state release
dry_release "${scratch}/1d.log"
grep -q "Found git tag v1.0.0" "${scratch}/1d.log" || { cat "${scratch}/1d.log"; fail "The next release does not count from v1.0.0."; }
grep -qi "the next release version is 1.1.0" "${scratch}/1d.log" || { cat "${scratch}/1d.log"; fail "The next release is not 1.1.0."; }
echo "::endgroup::"

echo "::group::2. tag pushed, GitHub release missing"
# The second commit's release: commit and tag pushed, then the GitHub
# plugin failed.
cd "${scratch}/run-1d"
release_commit 1.1.0
git tag v1.1.0
git push --quiet origin main
git push --quiet origin v1.1.0
release2="$(git rev-parse HEAD)"

checkout 2a "${second}"
state GITHUB_RELEASE_EXISTS=false
expect state finish
expect tag v1.1.0
expect sha "${release2}"
expect create-tag false
expect create-github-release true
expect latest true
before="$(remote_tags)"
finish
[ "$(remote_tags)" = "${before}" ] || fail "Finishing a GitHub release changed the tags."
state GITHUB_RELEASE_EXISTS=true
expect create-github-release false
# The next push to main finds 1.1.0 and nothing new to release.
checkout 2b "${release2}"
dry_release "${scratch}/2b.log"
if ! grep -q "Found git tag v1.1.0" "${scratch}/2b.log" \
   || ! grep -q "There are no relevant changes, so no new version is released." "${scratch}/2b.log"; then
  cat "${scratch}/2b.log"
  fail "A release of the released commit would release again."
fi
echo "::endgroup::"

echo "::group::3. tag pushed, major tag not moved"
# The repository keeps major tags: v1 was moved onto 1.0.0, and 1.1.0's
# move never happened.
cd "${scratch}/repo"
git fetch --quiet --tags origin
git tag v1 v1.0.0
git push --quiet origin v1

checkout 3a "${second}"
state GITHUB_RELEASE_EXISTS=true
expect move-major-tag true
expect major v1
finish
[ "$(remote_tag_commit v1)" = "${release2}" ] || fail "v1 was not moved onto v1.1.0."

checkout 3b "${second}"
state GITHUB_RELEASE_EXISTS=true
expect move-major-tag false
finish

checkout 3c "${first}"
state GITHUB_RELEASE_EXISTS=true
expect tag v1.0.0
expect move-major-tag false
expect latest false
finish
[ "$(remote_tag_commit v1)" = "${release2}" ] || fail "Finishing v1.0.0 moved v1 back."
[ "$(remote_tags)" = "v1 v1.0.0 v1.1.0 " ] || fail "The remote holds tags '$(remote_tags)'."
echo "::endgroup::"

echo "::group::4. the reconciler's ref"
checkout 4 "${first}"
state TARGET_REF=v1.1.0 GITHUB_REF=refs/heads/dev GITHUB_RELEASE_EXISTS=true
expect state finish
expect sha "${release2}"
expect create-tag false
echo "A ref that is no release tag:"
refuses TARGET_REF=main
echo "A release tag that does not exist:"
refuses TARGET_REF=v9.9.9
git checkout --quiet --orphan side
git commit --quiet --allow-empty --message "feat: off main"
git tag v0.9.0
echo "A release tag off main:"
refuses TARGET_REF=v0.9.0
echo "::endgroup::"

echo "::group::5. main only"
checkout 5 "${second}"
echo "A release on dev:"
refuses GITHUB_REF=refs/heads/dev
state GITHUB_REF=refs/heads/dev DRY_RUN=true GITHUB_RELEASE_EXISTS=true
expect state finish
echo "::endgroup::"

[ "$(release_commits 1.0.0)" -eq 1 ] && [ "$(release_commits 1.1.0)" -eq 1 ] \
  || fail "main holds a duplicate release commit."
[ "$(remote_tags)" = "v1 v1.0.0 v1.1.0 " ] || fail "The remote holds tags '$(remote_tags)'."
echo "A re-run finishes a stopped release with one tag and one release commit per version."

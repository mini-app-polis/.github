#!/usr/bin/env bash
# Work out what a release run on this commit has to do, and change nothing.
#
# The release stage's contract: a tag already on this commit is this
# commit's release, and the stage finishes what is missing rather than
# cutting another. This script is the "what is missing" half, kept apart
# from the half that pushes and calls GitHub so it can be proved against a
# scratch repository (scripts/check-release-resume.sh). It reads git and its
# environment only.
#
# A commit's release is found in one of three places, in this order:
#
#   1. a vX.Y.Z tag on the commit itself (a repository whose .releaserc has
#      no @semantic-release/git, or the reconciler's `ref`);
#   2. the commit itself, when it is a release commit with no tag;
#   3. the release commit @semantic-release/git pushed on top of it: the
#      next commit on the release branch, whose first parent is this commit
#      and whose subject is the fleet's release message,
#      `chore(release): X.Y.Z [skip ci]`. Its tag may or may not be there.
#
# None of them: `state=release`, and semantic-release runs as it always has.
# Otherwise `state=finish`: semantic-release does not run (it would refuse,
# with the branch ahead of this commit, or cut a second release commit for
# the same version), and the finish step does what the outputs below say is
# missing.
#
# Refuses (exit 1) to run anything but a dry run off the release branch, a
# `ref` that is not a vX.Y.Z tag on the release branch, a tag that disagrees
# with the release commit it should be on, and a release whose history holds
# an earlier release commit that was never tagged: releasing on top of that
# would cut the same version again, in a second release commit.
#
# Environment (all optional):
#   TARGET_REF             A vX.Y.Z tag to finish (the reconciler's `ref`).
#                          Empty: HEAD.
#   RELEASE_BRANCH         The branch releases are cut on. Default main.
#   REMOTE                 The remote to read it from. Default origin.
#   GITHUB_REF             The run's ref. Checked unless TARGET_REF or DRY_RUN.
#   DRY_RUN                "true": a dry run, which may run on any branch.
#   GITHUB_RELEASE_EXISTS  "true" or "false" once the caller has asked
#                          GitHub whether the tag has a release. Empty: not
#                          asked yet.
#   MAJOR_TAGS             "auto" (default): move the major tag only in a
#                          repository that already has a bare vN tag.
#                          "true" or "false" to say so outright.
#
# Prints key=value lines, for $GITHUB_OUTPUT:
#   state                  release | finish
#   tag, version, sha      The release's tag, version and commit (finish).
#   create-tag             true when the release commit has no tag yet.
#   create-github-release  true | false | unknown (GITHUB_RELEASE_EXISTS empty).
#   move-major-tag         true when the major tag should be moved onto sha.
#   major                  The major tag, vN.
#   latest                 true when the tag is the newest vX.Y.Z tag.
#   release-commit         true when sha is a release commit, whose message
#                          body holds the release notes.
set -euo pipefail

release_branch="${RELEASE_BRANCH:-main}"
remote="${REMOTE:-origin}"
target_ref="${TARGET_REF:-}"
dry_run="${DRY_RUN:-false}"
github_release_exists="${GITHUB_RELEASE_EXISTS:-}"
major_tags="${MAJOR_TAGS:-auto}"

# The fleet's release tags and release commit subject (.releaserc's
# @semantic-release/git message). No fleet repository cuts prereleases.
semver_tag='^v[0-9]+\.[0-9]+\.[0-9]+$'
release_subject='^chore\(release\): ([0-9]+\.[0-9]+\.[0-9]+)( \[skip ci\])?$'

refuse() {
  echo "::error::$*" >&2
  exit 1
}

# The version a release commit's subject names, or nothing.
release_version() {
  local subject
  subject="$(git log -1 --format=%s "$1")"
  if [[ "${subject}" =~ ${release_subject} ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# The commit a tag points at, or nothing when there is no such tag.
tag_commit() {
  git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true
}

# Every vX.Y.Z tag, oldest version first.
semver_tags() {
  git tag --list 'v*' | grep -E "${semver_tag}" | sort -V || true
}

branch="refs/remotes/${remote}/${release_branch}"
git rev-parse -q --verify "${branch}" >/dev/null \
  || refuse "${remote}/${release_branch} is not in this checkout: check out with fetch-depth: 0."

on_branch() {
  git merge-base --is-ancestor "$1" "${branch}"
}

if [ -n "${target_ref}" ]; then
  [[ "${target_ref}" =~ ${semver_tag} ]] \
    || refuse "ref '${target_ref}' is not a vX.Y.Z release tag. A run given a ref only finishes that release; it never cuts one."
  target="$(tag_commit "${target_ref}")"
  [ -n "${target}" ] || refuse "ref ${target_ref} is not a tag in this repository."
  on_branch "${target}" \
    || refuse "ref ${target_ref} is not on ${release_branch}. Releases are cut and finished on ${release_branch} only."
else
  target="$(git rev-parse HEAD)"
  if [ "${dry_run}" != "true" ]; then
    [ "${GITHUB_REF:-}" = "refs/heads/${release_branch}" ] \
      || refuse "This run is on '${GITHUB_REF:-an unknown ref}'. A release is cut on ${release_branch} only; anywhere else, run it as a dry run."
    on_branch "${target}" \
      || refuse "${target} is not on ${remote}/${release_branch}. A release is cut on ${release_branch} only."
  fi
fi

tag=""
sha=""
create_tag="false"

# 1. A release tag on the commit itself. Two would be two releases of one
# commit; the newer is reported.
on_target="$(git tag --points-at "${target}" --list 'v*' | grep -E "${semver_tag}" | sort -V | tail -n1 || true)"
if [ -n "${on_target}" ]; then
  tag="${on_target}"
  sha="${target}"
fi

# 2. The commit is itself a release commit, untagged.
if [ -z "${tag}" ]; then
  version="$(release_version "${target}")"
  if [ -n "${version}" ]; then
    tag="v${version}"
    sha="${target}"
  fi
fi

# 3. The release commit on top of it.
if [ -z "${tag}" ] && on_branch "${target}"; then
  # The oldest commit after it on the branch. tail, not head: head would
  # close the pipe on a long history and fail the script under pipefail.
  child="$(git rev-list --first-parent "${target}..${branch}" | tail -n1)"
  if [ -n "${child}" ] && [ "$(git rev-parse "${child}^1")" = "${target}" ]; then
    version="$(release_version "${child}")"
    if [ -n "${version}" ]; then
      tag="v${version}"
      sha="${child}"
    fi
  fi
fi

if [ -z "${tag}" ]; then
  # Nothing released this commit yet. Refuse to release on top of a release
  # commit that never got its tag: semantic-release would count from the tag
  # before it and cut the same version again.
  last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "${target}" 2>/dev/null || true)"
  range="${target}"
  if [ -n "${last}" ]; then
    range="${last}..${target}"
  fi
  while read -r commit; do
    [ -n "${commit}" ] || continue
    version="$(release_version "${commit}")"
    if [ -n "${version}" ] && [ -z "$(tag_commit "v${version}")" ]; then
      refuse "Release commit ${commit} (${version}) has no tag v${version}. Re-run the release job of the run that made it, which finishes it, before releasing anything after it."
    fi
  done < <(git rev-list --first-parent "${range}")
  echo "state=release"
  exit 0
fi

# The tag must be on the commit that carries the release, or nowhere yet.
existing="$(tag_commit "${tag}")"
if [ -z "${existing}" ]; then
  create_tag="true"
elif [ "${existing}" != "${sha}" ]; then
  refuse "${tag} is on ${existing}, but this commit's release is ${sha}. Two commits claim one version: settle it by hand."
fi

version="${tag#v}"
major="v${version%%.*}"

# The major tag moves only onto the newest release of its major, so finishing
# an old release never drags it back, and only in a repository that keeps
# major tags (move-major-tag.sh refuses to move one below a newer bare major).
move_major="false"
if [ "${major_tags}" = "auto" ]; then
  if git tag --list 'v*' | grep -qE '^v[0-9]+$'; then
    major_tags="true"
  else
    major_tags="false"
  fi
fi
if [ "${major_tags}" = "true" ]; then
  newest_in_major="$( { semver_tags; echo "${tag}"; } | grep -E "^${major}\." | sort -V | tail -n1)"
  highest_bare="$(git tag --list 'v*' | grep -E '^v[0-9]+$' | sed 's/^v//' | sort -n | tail -n1 || true)"
  if [ "${newest_in_major}" = "${tag}" ] \
     && { [ -z "${highest_bare}" ] || [ "${version%%.*}" -ge "${highest_bare}" ]; } \
     && [ "$(tag_commit "${major}")" != "${sha}" ]; then
    move_major="true"
  fi
fi

latest="false"
if [ "$( { semver_tags; echo "${tag}"; } | sort -V | tail -n1)" = "${tag}" ]; then
  latest="true"
fi

release_commit="false"
if [ -n "$(release_version "${sha}")" ]; then
  release_commit="true"
fi

case "${github_release_exists}" in
  true) create_github_release="false" ;;
  false) create_github_release="true" ;;
  *) create_github_release="unknown" ;;
esac

cat <<EOF
state=finish
tag=${tag}
version=${version}
sha=${sha}
create-tag=${create_tag}
create-github-release=${create_github_release}
move-major-tag=${move_major}
major=${major}
latest=${latest}
release-commit=${release_commit}
EOF

#!/usr/bin/env bash
#
# Open, or refresh, the one pull request that carries a re-locked uv.lock
# into `dev`. Shared by the two fleet workflows that re-lock other
# repositories: dependency-fix.yml (vulnerable packages) and
# commons-update.yml (a new release of the fleet's own libraries).
#
# Run from the target repository's working tree, checked out at `dev`, with
# the new uv.lock in place and uncommitted. The branch is always exactly one
# commit on top of `dev`, so:
#
#   - if the remote branch already is that commit — its parent is the
#     current `dev` and its uv.lock is this one — nothing is pushed. An
#     unmerged update does not restart CI every time the workflow runs.
#   - otherwise the commit is made afresh on `dev` and force-pushed over
#     whatever the branch held.
#
# Then the open pull request from the branch into `dev` gets this title and
# body, or one is opened.
#
# The commit is authored as the App whose token is in GH_TOKEN, so the push
# starts the repository's CI and automerge.yml can merge it.
#
# Usage: open-lock-pr.sh <owner/repo> <branch> <subject-file> <body-file>
# Env:   GH_TOKEN  the App installation token
#        SLUG      the App's slug (create-github-app-token's app-slug output)

set -euo pipefail

repo="${1:?usage: open-lock-pr.sh <owner/repo> <branch> <subject-file> <body-file>}"
branch="${2:?branch}"
subject_file="${3:?subject file}"
body_file="${4:?body file}"
: "${SLUG:?SLUG must name the App}"

subject=$(cat "$subject_file")
msg=$(mktemp)
trap 'rm -f "$msg"' EXIT

if git fetch --depth=2 origin "$branch" 2>/dev/null \
   && [ "$(git rev-parse FETCH_HEAD~1)" = "$(git rev-parse HEAD)" ] \
   && git diff --quiet FETCH_HEAD -- uv.lock; then
  echo "$branch already carries this uv.lock on top of dev; leaving it."
else
  id=$(gh api "/users/${SLUG}%5Bbot%5D" --jq .id)
  git config user.name "${SLUG}[bot]"
  git config user.email "${id}+${SLUG}[bot]@users.noreply.github.com"
  git switch -c "$branch"
  git add uv.lock
  { echo "$subject"; echo; cat "$body_file"; } > "$msg"
  git commit -q -F "$msg"
  git push --force origin "$branch"
fi

pr=$(gh pr list -R "$repo" --head "$branch" --base dev --state open --json number --jq '.[0].number // empty')
if [ -n "$pr" ]; then
  gh pr edit "$pr" -R "$repo" --title "$subject" --body-file "$body_file"
  echo "Refreshed #$pr."
else
  gh pr create -R "$repo" --base dev --head "$branch" --title "$subject" --body-file "$body_file"
fi

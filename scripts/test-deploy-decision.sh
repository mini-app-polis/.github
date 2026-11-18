#!/usr/bin/env bash
# Proves deploy-decision.sh, the deploy stage's two decisions: whether a run
# may deploy to an environment at all (guard), and whether the target
# already runs the version it would deploy (decide). Run by the self-test,
# and by hand:
#
#   bash scripts/test-deploy-decision.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/../.github/actions/deploy-decision/deploy-decision.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

failures=0
pass() { echo "ok: $1"; }
fail() { echo "::error::$1"; failures=$((failures + 1)); }

accepts() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then pass "${what}"; else fail "${what}: refused ($(cat "${work}/err"))"; fi
}
refuses() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then fail "${what}: accepted"; else pass "${what}"; fi
}
# Expect decide to print the verdict.
verdict() {
  local what="$1" want="$2"; shift 2
  local got
  if ! got="$("${tool}" decide "$@" 2> "${work}/err" | sed -n 1p)"; then
    fail "${what}: decide failed ($(cat "${work}/err"))"
    return
  fi
  [ "${got}" = "${want}" ] && pass "${what}: ${want}" || fail "${what}: ${got}, wanted ${want}"
}

V=1.4.0
ID=sha256:aaaa
OTHER=sha256:bbbb
DEV=1.4.0+g0123456789ab

# guard
accepts "production takes a release from main" "${tool}" guard production live refs/heads/main "${V}"
accepts "development takes a build version from dev" "${tool}" guard development live refs/heads/dev "${DEV}"
accepts "development takes a release version from dev" "${tool}" guard development live refs/heads/dev "${V}"
refuses "production refuses a build version" "${tool}" guard production live refs/heads/main "${DEV}"
refuses "production refuses a pre-release" "${tool}" guard production live refs/heads/main "1.4.0-rc.1"
refuses "production refuses a v-prefixed tag" "${tool}" guard production live refs/heads/main "v1.4.0"
refuses "production refuses dev" "${tool}" guard production live refs/heads/dev "${V}"
refuses "production refuses a pull request" "${tool}" guard production live refs/pull/7/merge "${V}"
refuses "development refuses main" "${tool}" guard development live refs/heads/main "${DEV}"
refuses "development refuses a feature branch" "${tool}" guard development live refs/heads/feature "${DEV}"
accepts "a fake target deploys from any ref" "${tool}" guard production fake refs/pull/7/merge "${V}"
refuses "a fake production deploy still needs a release" "${tool}" guard production fake refs/pull/7/merge "${DEV}"
refuses "an unknown environment" "${tool}" guard staging live refs/heads/main "${V}"
refuses "an unknown target" "${tool}" guard production real refs/heads/main "${V}"
refuses "no version" "${tool}" guard development live refs/heads/dev ""

# decide
verdict "nothing deployed yet" deploy "${V}" "${ID}" "" ""
verdict "the same version and artifact" skip "${V}" "${ID}" "${V}" "${ID}"
verdict "the same version, rebuilt" skip "${V}" "${ID}" "${V}" "${OTHER}"
verdict "the same version, no identity reported" skip "${V}" "${ID}" "${V}" ""
verdict "an older version" deploy "${V}" "${ID}" "1.3.9" "${OTHER}"
verdict "a newer version is replaced (a rollback)" deploy "${V}" "${ID}" "1.5.0" "${OTHER}"
verdict "no version recorded, same artifact (Lambda)" skip "${V}" "${ID}" "" "${ID}"
verdict "no version recorded, other artifact (Lambda)" deploy "${V}" "${ID}" "" "${OTHER}"
verdict "the same artifact under another version" deploy "${V}" "${ID}" "${DEV}" "${ID}"
verdict "a build version differs from its release" deploy "${V}" "${ID}" "${DEV}" "${OTHER}"
verdict "dev: the same build version" skip "${DEV}" "${ID}" "${DEV}" "${ID}"
refuses "decide needs a version" "${tool}" decide "" "${ID}" "" ""
refuses "decide needs an identity" "${tool}" decide "${V}" "" "" ""
refuses "decide needs four arguments" "${tool}" decide "${V}" "${ID}"

# The reason is on the second line, and names the version.
reason="$("${tool}" decide "${V}" "${ID}" "${V}" "${ID}" | sed -n 2p)"
[[ "${reason}" == *"${V}"* ]] && pass "the reason names the version" || fail "the reason was '${reason}'"

if [ "${failures}" -ne 0 ]; then
  echo "::error::${failures} deploy decision case(s) failed."
  exit 1
fi
echo "Every deploy decision case passed."

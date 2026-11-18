#!/usr/bin/env bash
# Proves artifact-digest.sh, the check every stage after `build` runs on the
# artifact it takes: a sealed artifact verifies against its own digest, and
# a wrong digest, a changed, added or removed file, a missing seal or a
# malformed digest each fails it. Run by the self-test, and by hand:
#
#   bash scripts/test-artifact-digest.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/../.github/actions/artifact-digest/artifact-digest.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

failures=0
pass() { echo "ok: $1"; }
fail() { echo "::error::$1"; failures=$((failures + 1)); }

# Expect the command to succeed.
accepts() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then pass "${what}"; else fail "${what}: refused ($(cat "${work}/err"))"; fi
}
# Expect the command to fail.
refuses() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then fail "${what}: accepted"; else pass "${what}"; fi
}

fresh() {
  rm -rf "${work}/a"
  mkdir -p "${work}/a/dist" "${work}/a/lambda"
  printf 'wheel\n' > "${work}/a/dist/pkg-1.0.0-py3-none-any.whl"
  printf 'sdist\n' > "${work}/a/dist/pkg-1.0.0.tar.gz"
  printf 'zip\n' > "${work}/a/lambda/worker.zip"
  printf 'odd\n' > "${work}/a/dist/a name with spaces"
  "${tool}" seal "${work}/a"
}

digest="$(fresh)"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] && pass "seal prints a sha256 digest" || fail "seal printed '${digest}'"
accepts "verify with the sealed digest" "${tool}" verify "${work}/a" "${digest}"
accepts "check with no digest" "${tool}" check "${work}/a"
[ "$("${tool}" check "${work}/a")" = "${digest}" ] && pass "check reports the sealed digest" || fail "check reported another digest"

# The same files sealed again, in a new directory, give the same digest.
cp -r "${work}/a" "${work}/b"
rm "${work}/b/SHA256SUMS"
[ "$("${tool}" seal "${work}/b")" = "${digest}" ] && pass "the same files seal to the same digest" || fail "the same files sealed to another digest"

# The planted mismatch: a well-formed digest that is not this artifact's.
other="sha256:$(printf 'not this artifact' | sha256sum | cut -d' ' -f1)"
refuses "verify with another artifact's digest" "${tool}" verify "${work}/a" "${other}"
grep -q "Digest mismatch" "${work}/err" && pass "a mismatch says so" || fail "a mismatch did not say so: $(cat "${work}/err")"

fresh > /dev/null
printf 'tampered\n' > "${work}/a/lambda/worker.zip"
refuses "verify after a file changed" "${tool}" verify "${work}/a" "${digest}"

fresh > /dev/null
printf 'extra\n' > "${work}/a/dist/extra.whl"
refuses "verify with a file added" "${tool}" verify "${work}/a" "${digest}"

fresh > /dev/null
rm "${work}/a/dist/pkg-1.0.0.tar.gz"
refuses "verify with a file removed" "${tool}" verify "${work}/a" "${digest}"

fresh > /dev/null
rm "${work}/a/SHA256SUMS"
refuses "verify with no seal" "${tool}" verify "${work}/a" "${digest}"

fresh > /dev/null
refuses "verify with a malformed digest" "${tool}" verify "${work}/a" "${digest#sha256:}"

mkdir -p "${work}/empty"
refuses "seal an empty directory" "${tool}" seal "${work}/empty"

fresh > /dev/null
rm "${work}/a/SHA256SUMS"
printf 'x\n' > "${work}/a/dist/.gitignore"
refuses "seal a hidden file" "${tool}" seal "${work}/a"

if [ "${failures}" -ne 0 ]; then
  echo "::error::${failures} artifact-digest case(s) failed."
  exit 1
fi
echo "Every artifact-digest case passed."

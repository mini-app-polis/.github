#!/usr/bin/env bash
# Seals a build artifact's directory with a manifest of its files, and checks
# a directory against one, so a later stage can prove it holds exactly what
# the build stage made.
#
#   artifact-digest.sh seal <dir>            write <dir>/SHA256SUMS, print the digest
#   artifact-digest.sh check <dir>           fail unless <dir> matches its SHA256SUMS; print the digest
#   artifact-digest.sh verify <dir> <digest> check, and fail unless the digest is <digest>
#
# The manifest is `sha256sum` over every file under <dir> but itself, by path
# in byte order, so the same files always give the same manifest. The
# artifact's digest is `sha256:` and the SHA-256 of that manifest. One digest
# then covers an artifact of several files (a wheel and its sdist) as well as
# one of a single file, and `check` fails on a changed, missing or added file
# alike, since any of them changes the manifest.
set -euo pipefail

manifest() {
  (
    cd "$1"
    find . -type f ! -path ./SHA256SUMS -printf '%P\0' \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum --
  )
}

digest_of() {
  printf 'sha256:%s\n' "$(sha256sum < "$1/SHA256SUMS" | cut -d' ' -f1)"
}

usage() {
  echo "usage: $0 seal <dir> | check <dir> | verify <dir> <sha256:hex>" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
mode="$1"
dir="$2"
[ -d "${dir}" ] || { echo "::error::${dir} is not a directory." >&2; exit 1; }

case "${mode}" in
  seal)
    [ "$#" -eq 2 ] || usage
    # upload-artifact leaves hidden files out, so one sealed here would be
    # missing from every download and fail its check.
    hidden="$(cd "${dir}" && find . -name '.*' ! -name . -print -quit)"
    if [ -n "${hidden}" ]; then
      echo "::error::${dir} holds a hidden file (${hidden#./}), which an upload would leave out." >&2
      exit 1
    fi
    sums="$(manifest "${dir}")"
    if [ -z "${sums}" ]; then
      echo "::error::${dir} holds no files to seal." >&2
      exit 1
    fi
    printf '%s\n' "${sums}" > "${dir}/SHA256SUMS"
    digest_of "${dir}"
    ;;
  check|verify)
    if [ "${mode}" = verify ]; then
      [ "$#" -eq 3 ] || usage
      expected="$3"
      if ! [[ "${expected}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "::error::'${expected}' is not a digest of the form sha256:<64 hex digits>." >&2
        exit 1
      fi
    else
      [ "$#" -eq 2 ] || usage
    fi
    if [ ! -f "${dir}/SHA256SUMS" ]; then
      echo "::error::${dir} has no SHA256SUMS: it was not sealed by the build stage." >&2
      exit 1
    fi
    if ! diff -u "${dir}/SHA256SUMS" <(manifest "${dir}") >&2; then
      echo "::error::The files in ${dir} are not the ones its SHA256SUMS lists (diff above: - sealed, + found)." >&2
      exit 1
    fi
    actual="$(digest_of "${dir}")"
    if [ "${mode}" = verify ] && [ "${actual}" != "${expected}" ]; then
      echo "::error::Digest mismatch: expected ${expected}, found ${actual}." >&2
      exit 1
    fi
    echo "${actual}"
    ;;
  *)
    usage
    ;;
esac

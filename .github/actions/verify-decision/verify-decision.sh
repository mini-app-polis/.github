#!/usr/bin/env bash
# The verify stage's decisions, kept out of the workflow so they can be
# tested on their own (scripts/test-verify-decision.sh):
#
#   wants <version> [build-version]
#       The versions a running service may report and count as this
#       release, one per line, deduplicated, in order:
#         - version itself (the release's X.Y.Z in production, the build's
#           version in development);
#         - build-version, the build stage's version (X.Y.Z+g<sha>), for a
#           service that reports what it was built as;
#         - each of those without its "+..." part: what the commit
#           declares in pyproject.toml or package.json, and so what a
#           service built from it reports today.
#       On main the artifact is built before the release commit writes the
#       new version, so a service built from it reports the version its
#       commit declared (README, "Verify stage", says why that is accepted
#       and what else is checked alongside it).
#
#   compare <reported> <want>...
#       Prints "match", "mismatch" or "pending" on the first line and the
#       reason on the second. pending is an empty report: the target did
#       not answer, or answered without a version.
#
#   delay <attempt> <initial-seconds> <max-seconds>
#       Seconds to wait after the given attempt (1, 2, ...): initial,
#       doubling each attempt, capped at max.
#
#   poll <timeout-seconds> <initial-seconds> <max-seconds> <wants> -- <probe> [args...]
#       Runs the probe until what it prints matches one of wants (space
#       separated), or until waiting again would pass timeout-seconds. The
#       probe prints what the target reports on its first line and exits
#       0; a probe that exits non-zero has not got an answer yet, and its
#       last line of stderr is kept as the reason. Each attempt is bounded
#       by VERIFY_PROBE_SECONDS (default 60).
#       Prints three lines: "verified" or "timeout", the last report, and
#       the reason. Exits 0 when verified and 1 on timeout.
set -euo pipefail

usage() {
  echo "usage: $0 wants <version> [build-version]" >&2
  echo "       $0 compare <reported> <want>..." >&2
  echo "       $0 delay <attempt> <initial-seconds> <max-seconds>" >&2
  echo "       $0 poll <timeout-seconds> <initial-seconds> <max-seconds> <wants> -- <probe> [args...]" >&2
  exit 2
}

is_count() { [[ "$1" =~ ^[0-9]+$ ]]; }

wants() {
  local version="${1:-}" build="${2:-}"
  if [ -z "${version}" ]; then
    echo "wants: no version" >&2
    return 2
  fi
  local candidate seen=" "
  for candidate in "${version}" "${build}" "${version%%+*}" "${build%%+*}"; do
    [ -n "${candidate}" ] || continue
    case "${seen}" in *" ${candidate} "*) continue ;; esac
    seen="${seen}${candidate} "
    echo "${candidate}"
  done
}

compare() {
  [ "$#" -ge 2 ] || { echo "compare: needs a report and at least one wanted value" >&2; return 2; }
  local reported="$1"; shift
  if [ -z "${reported}" ]; then
    echo pending
    echo "The target reported nothing yet; wanted $*."
    return 0
  fi
  local want
  for want in "$@"; do
    if [ "${reported}" = "${want}" ]; then
      echo match
      echo "The target reports ${reported}."
      return 0
    fi
  done
  echo mismatch
  echo "The target reports ${reported}; wanted $*."
}

delay() {
  local attempt="${1:-}" initial="${2:-}" max="${3:-}"
  if ! is_count "${attempt}" || ! is_count "${initial}" || ! is_count "${max}" || [ "${attempt}" -lt 1 ]; then
    echo "delay: attempt (1 or more), initial and max are whole seconds" >&2
    return 2
  fi
  local d="${initial}" i=1
  while [ "${i}" -lt "${attempt}" ] && [ "${d}" -lt "${max}" ]; do
    d=$(( d * 2 ))
    i=$(( i + 1 ))
  done
  [ "${d}" -gt "${max}" ] && d="${max}"
  echo "${d}"
}

poll() {
  [ "$#" -ge 6 ] && [ "$5" = "--" ] || usage
  local timeout="$1" initial="$2" max="$3" want_list="$4"
  shift 5
  if ! is_count "${timeout}" || ! is_count "${initial}" || ! is_count "${max}"; then
    echo "poll: timeout, initial and max are whole seconds" >&2
    return 2
  fi
  local -a want
  read -r -a want <<< "${want_list}"
  if [ "${#want[@]}" -eq 0 ]; then
    echo "poll: nothing to want" >&2
    return 2
  fi
  local err
  err="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the path is local to this call
  trap "rm -f '${err}'" RETURN

  local start attempt=0 reported="" verdict reason="" out wait elapsed
  start="$(date +%s)"
  while :; do
    attempt=$(( attempt + 1 ))
    if out="$(timeout "${VERIFY_PROBE_SECONDS:-60}" "$@" 2> "${err}")"; then
      reported="$(head -n1 <<< "${out}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      out="$(compare "${reported}" "${want[@]}")"
      verdict="$(sed -n 1p <<< "${out}")"
      reason="$(sed -n 2p <<< "${out}")"
    else
      reported=""
      verdict=pending
      reason="Not answering yet: $(tail -n1 "${err}" 2> /dev/null || true)"
    fi
    echo "attempt ${attempt}: ${verdict}: ${reason}" >&2
    if [ "${verdict}" = match ]; then
      echo verified
      echo "${reported}"
      echo "${reason} (attempt ${attempt})"
      return 0
    fi
    wait="$(delay "${attempt}" "${initial}" "${max}")"
    elapsed=$(( $(date +%s) - start ))
    if [ $(( elapsed + wait )) -gt "${timeout}" ]; then
      echo timeout
      echo "${reported}"
      echo "Timed out after ${elapsed}s and ${attempt} attempt(s): ${reason}"
      return 1
    fi
    sleep "${wait}"
  done
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "${cmd}" in
  wants) wants "$@" ;;
  compare) compare "$@" ;;
  delay) delay "$@" ;;
  poll) poll "$@" ;;
  *) usage ;;
esac

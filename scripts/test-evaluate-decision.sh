#!/usr/bin/env bash
# Proves the evaluation stages' request and decisions (evaluate-decision.sh):
# the request body, what blocks a release and what passes it, the backoff,
# and the request and poll against the stand-in API (stand-in.py) in each of
# its scenarios: a clean evaluation passes, an ERROR blocks, findings that
# are never closed time out, a missing route fails at once, and a refused
# request is reported as not accepted. Nothing here reaches the real API.
# Run by the self-test, and by hand:
#
#   bash scripts/test-evaluate-decision.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${here}/../.github/actions/evaluate-decision"
tool="${dir}/evaluate-decision.sh"
work="$(mktemp -d)"
server_pid=""
stop_server() {
  [ -n "${server_pid}" ] && kill "${server_pid}" 2> /dev/null || true
  server_pid=""
}
cleanup() {
  stop_server
  rm -rf "${work}"
}
trap cleanup EXIT

failures=0
pass() { echo "ok: $1"; }
fail() { echo "::error::$1"; failures=$((failures + 1)); }
refuses() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then fail "${what}: accepted"; else pass "${what}"; fi
}
line() { sed -n "$1p"; }

SHA=0123456789abcdef0123456789abcdef01234567

# ---- body ------------------------------------------------------------------
b="$("${tool}" body pre-release watcher-cog mini-app-polis "${SHA}" main)"
jq -e --arg sha "${SHA}" '. == {repo: "watcher-cog", org: "mini-app-polis", ref: "main", mode: "deterministic", sha: $sha, phase: "pre-release"}' <<< "${b}" > /dev/null \
  && pass "a pre-release body pins the commit, the phase and the deterministic engine" || fail "pre-release body: ${b}"
b="$("${tool}" body post-release watcher-cog mini-app-polis "${SHA}" v1.4.0)"
jq -e '.phase == "post-release" and .ref == "v1.4.0"' <<< "${b}" > /dev/null \
  && pass "a post-release body names the release" || fail "post-release body: ${b}"
refuses "an unknown phase" "${tool}" body mid-release watcher-cog mini-app-polis "${SHA}" main
refuses "an abbreviated sha" "${tool}" body pre-release watcher-cog mini-app-polis 0123456 main
refuses "an upper-case sha" "${tool}" body pre-release watcher-cog mini-app-polis "${SHA^^}" main
refuses "a branch for a sha" "${tool}" body pre-release watcher-cog mini-app-polis main main
refuses "no repo" "${tool}" body pre-release "" mini-app-polis "${SHA}" main

# ---- decide ----------------------------------------------------------------
answer() {
  # state, then severity=count pairs; a finding row for each blocking count.
  local state="$1"; shift
  local counts='{"CRITICAL": 0, "ERROR": 0, "WARN": 0, "INFO": 0, "SUCCESS": 0}' findings='[]' kv
  for kv in "$@"; do
    counts="$(jq -c --arg k "${kv%=*}" --argjson v "${kv#*=}" '.[$k] = $v' <<< "${counts}")"
    findings="$(jq -c --arg k "${kv%=*}" '. + [{violation_id: "CD-026", severity: $k, dimension: "cd_readiness", finding: "a finding\nover two lines"}]' <<< "${findings}")"
  done
  jq -n --arg s "${state}" --argjson c "${counts}" --argjson f "${findings}" \
    '{data: {state: $s, run_id: "deterministic-7.0.0-abc", counts: $c, findings: $f}}' > "${work}/answer.json"
  "${tool}" decide "${work}/answer.json"
}
decides() {
  local what="$1" want="$2"; shift 2
  local got
  got="$(answer "$@" | line 1)"
  [ "${got}" = "${want}" ] && pass "${what}" || fail "${what}: got ${got}, wanted ${want}"
}
decides "a clean, complete evaluation passes" pass complete SUCCESS=1
decides "WARN and INFO do not block" pass complete WARN=3 INFO=2 SUCCESS=1
decides "an ERROR blocks" blocked complete ERROR=1 SUCCESS=1
decides "a CRITICAL blocks" blocked running CRITICAL=1
decides "an ERROR blocks before the evaluation is complete" blocked running WARN=1 ERROR=1
decides "findings with nothing to close them wait" pending running WARN=2
decides "nothing arrived waits" pending pending
reason="$(answer running ERROR=2 | line 2)"
[[ "${reason}" == *"2 blocking"*"ERROR CD-026"* && "${reason}" != *$'\n'* ]] \
  && pass "the blocking reason names the count and the rule, on one line" || fail "blocking reason: ${reason}"
echo '<!doctype html><title>Just a moment</title>' > "${work}/html.json"
[ "$("${tool}" decide "${work}/html.json" | line 1)" = pending ] && pass "an unreadable answer waits" || fail "an unreadable answer did not wait"
echo '{"data": {"state": "done"}}' > "${work}/odd.json"
[ "$("${tool}" decide "${work}/odd.json" | line 1)" = pending ] && pass "an unknown state waits" || fail "an unknown state did not wait"

# ---- delay -----------------------------------------------------------------
[ "$("${tool}" delay 1 10 60)" = 10 ] && pass "the first wait is the initial" || fail "first wait"
[ "$("${tool}" delay 3 10 60)" = 40 ] && pass "it doubles" || fail "doubling"
[ "$("${tool}" delay 9 10 60)" = 60 ] && pass "it stops at the cap" || fail "cap"
refuses "attempt 0" "${tool}" delay 0 10 60

# ---- request and poll, against the stand-in --------------------------------
start_server() {
  stop_server
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  : > "${work}/record.jsonl"
  python3 "${dir}/stand-in.py" "${port}" "$1" "${work}/record.jsonl" > "${work}/server.log" 2>&1 &
  server_pid=$!
  export EVALUATE_API_URL="http://127.0.0.1:${port}"
  for _ in $(seq 1 50); do curl -s -o /dev/null "${EVALUATE_API_URL}/health" && break; sleep 0.1; done
}
body="$("${tool}" body pre-release watcher-cog mini-app-polis "${SHA}" main)"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run() {
  # scenario, then poll's timeout initial max; prints exit:verdict, and
  # keeps what poll printed in poll.out (this runs in a subshell).
  local scenario="$1" st=0 out
  shift
  start_server "${scenario}"
  EVALUATE_API_KEY=fake-key "${tool}" request "${body}" > "${work}/message" 2> "${work}/request.err" || { echo "request-failed:$(cat "${work}/request.err")"; return; }
  out="$("${tool}" poll "$@" watcher-cog "${SHA}" pre-release "${since}" 2> /dev/null)" || st=$?
  echo "${out}" > "${work}/poll.out"
  echo "${st}:$(line 1 <<< "${out}")"
}

got="$(run clean 10 1 1)"
[ "${got}" = 0:pass ] && pass "a clean evaluation passes once it is complete" || fail "clean: ${got}"
[ "$(cat "${work}/message")" = standin-1 ] && pass "the request answers with its message id" || fail "message id: $(cat "${work}/message")"
[[ "$(line 3 < "${work}/poll.out")" == *"attempt 3"* ]] && pass "it waited through pending" || fail "clean took: $(line 3 < "${work}/poll.out")"
[ "$(line 2 < "${work}/poll.out")" = deterministic-0.0.0-standin ] && pass "the run id is reported" || fail "run id: $(line 2 < "${work}/poll.out")"
jq -se --arg sha "${SHA}" 'map(select(.method == "GET" and .path == "/v1/evaluations/runs/outcome")) | length >= 3 and all(.query.sha == $sha and .query.phase == "pre-release" and .query.since != null and .auth == null)' \
  "${work}/record.jsonl" > /dev/null \
  && pass "the outcome is read for the commit and phase asked, since the request, with no key" || fail "outcome reads: $(cat "${work}/record.jsonl")"

got="$(run blocking 10 1 1)"
[ "${got}" = 1:blocked ] && pass "an ERROR blocks" || fail "blocking: ${got}"
[[ "$(line 3 < "${work}/poll.out")" == *CD-026* ]] && pass "the block names the rule" || fail "block reason: $(line 3 < "${work}/poll.out")"

start=$(date +%s)
got="$(run running 3 1 1)"
took=$(( $(date +%s) - start ))
[ "${got}" = 3:timeout ] && pass "findings never closed time out, failing closed" || fail "running: ${got}"
[ "${took}" -le 6 ] && pass "the timeout is kept (${took}s of 3)" || fail "the poll ran ${took}s past a 3s timeout"

start=$(date +%s)
got="$(run missing 30 1 1)"
took=$(( $(date +%s) - start ))
[ "${got}" = 4:unsupported ] && [ "${took}" -le 3 ] && pass "no outcome route fails at once" || fail "missing: ${got} after ${took}s"

stop_server
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
st=0; EVALUATE_API_URL="http://127.0.0.1:${port}" "${tool}" poll 2 1 1 watcher-cog "${SHA}" pre-release "${since}" > "${work}/out" 2> /dev/null || st=$?
[ "${st}" = 3 ] && pass "an API that never answers times out" || fail "nothing listening exited ${st}"

start_server refuse
refuses "a refused request is not accepted" env EVALUATE_API_KEY=fake-key "${tool}" request "${body}"
grep -q 403 "${work}/err" && pass "the refusal says what the API answered" || fail "refusal: $(cat "${work}/err")"
start_server clean
refuses "the wrong key is not accepted" env EVALUATE_API_KEY=wrong "${tool}" request "${body}"
refuses "no key is not sent at all" env EVALUATE_API_KEY= "${tool}" request "${body}"
[ "$(jq -s 'map(select(.method == "POST")) | length' "${work}/record.jsonl")" = 1 ] \
  && pass "a missing key never reaches the API" || fail "posts: $(cat "${work}/record.jsonl")"

st=0; "${tool}" poll 5 1 1 watcher-cog "${SHA}" pre-release > /dev/null 2>&1 || st=$?
[ "${st}" = 2 ] && pass "a usage error is not a timeout (exit 2)" || fail "usage error exited ${st}"

if [ "${failures}" -ne 0 ]; then
  echo "::error::${failures} evaluate decision case(s) failed."
  exit 1
fi
echo "Every evaluate decision case passed."

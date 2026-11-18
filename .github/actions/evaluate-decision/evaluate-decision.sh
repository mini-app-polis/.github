#!/usr/bin/env bash
# The evaluation stages' request and decisions, kept out of the workflow so
# they can be tested on their own (scripts/test-evaluate-decision.sh):
#
#   body <phase> <repo> <org> <sha> <ref>
#       The JSON POST /v1/evaluations/runs takes: always the deterministic
#       engine, the commit pinned by its full sha, and the release phase.
#       Refuses a phase other than pre-release or post-release and a sha
#       that is not 40 lower-case hex characters: the outcome is read back
#       by the exact sha asked for, so an abbreviated one would be asked
#       for and then never found.
#
#   request <body>
#       POSTs the body to EVALUATE_API_URL/v1/evaluations/runs with the
#       EVALUATE_API_KEY bearer key. Prints the queue message id the API
#       answers with and exits 0 when it accepted; prints why on stderr and
#       exits 1 when it did not, telling a block at the edge from a refusal
#       by the API.
#
#   decide <answer-file>
#       Reads one answer of GET /v1/evaluations/runs/outcome. Prints
#       "pass", "blocked" or "pending" on the first line and the reason on
#       the second:
#         blocked  the evaluation holds a CRITICAL or ERROR finding. Decided
#                  as soon as one arrives, finished or not: findings are
#                  only ever added to a run, so it cannot be taken back.
#         pass     the evaluation is complete and holds neither.
#         pending  anything else: nothing has arrived, findings have
#                  arrived and nothing says they are all of them yet, or
#                  the answer could not be read.
#
#   delay <attempt> <initial-seconds> <max-seconds>
#       Seconds to wait after the given attempt (1, 2, ...): initial,
#       doubling each attempt, capped at max.
#
#   poll <timeout-seconds> <initial-seconds> <max-seconds> <repo> <sha> <phase> <since>
#       Asks EVALUATE_API_URL for the outcome of the evaluation of
#       (repo, sha, phase) that started at or after `since`, until it
#       decides or until waiting again would pass timeout-seconds. Prints
#       three lines: the verdict ("pass", "blocked", "timeout" or
#       "unsupported"), the run id the answer named, and the reason. Exits
#       0 on pass, 1 when blocked, 3 on timeout and 4 when the API has no
#       outcome route (404), which no amount of waiting changes. Each
#       request is bounded by EVALUATE_REQUEST_SECONDS (default 30). The
#       last answer read is copied to EVALUATE_ANSWER_FILE when it is set.
#
# Exit 2 is a usage error in every command.
set -euo pipefail

usage() {
  echo "usage: $0 body <phase> <repo> <org> <sha> <ref>" >&2
  echo "       $0 request <body>" >&2
  echo "       $0 decide <answer-file>" >&2
  echo "       $0 delay <attempt> <initial-seconds> <max-seconds>" >&2
  echo "       $0 poll <timeout-seconds> <initial-seconds> <max-seconds> <repo> <sha> <phase> <since>" >&2
  exit 2
}

# The severities that block a release: ecosystem-standards' index.yaml has
# ERROR as "requires remediation before next deploy", and CRITICAL as a
# failure that blocked the evaluation itself, which is no evaluation at all.
BLOCKING='["CRITICAL", "ERROR"]'

# A named client, not curl's default: the API sits behind Cloudflare, which
# refuses unidentified automation (evaluate.yml says how that was learned).
USER_AGENT="mini-app-polis-evaluate/1 (+https://github.com/mini-app-polis/.github)"

is_count() { [[ "$1" =~ ^[0-9]+$ ]]; }

body() {
  [ "$#" -eq 5 ] || usage
  local phase="$1" repo="$2" org="$3" sha="$4" ref="$5"
  case "${phase}" in
    pre-release|post-release) ;;
    *) echo "body: phase is '${phase}': it is pre-release or post-release" >&2; return 2 ;;
  esac
  if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "body: sha is '${sha}': the full 40-character commit sha, lower case" >&2
    return 2
  fi
  [ -n "${repo}" ] && [ -n "${org}" ] && [ -n "${ref}" ] || { echo "body: repo, org and ref are required" >&2; return 2; }
  jq -nc --arg repo "${repo}" --arg org "${org}" --arg ref "${ref}" --arg sha "${sha}" --arg phase "${phase}" \
    '{repo: $repo, org: $org, ref: $ref, mode: "deterministic", sha: $sha, phase: $phase}'
}

request() {
  [ "$#" -eq 1 ] || usage
  local payload="$1" url="${EVALUATE_API_URL:-}" key="${EVALUATE_API_KEY:-}"
  [ -n "${url}" ] || { echo "request: EVALUATE_API_URL is not set" >&2; return 2; }
  if [ -z "${key}" ]; then
    echo "No api-key: pass the organisation secret CI_VALIDATOR_API_KEY as the stage's api-key." >&2
    return 1
  fi
  local out status
  out="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the path is local to this call
  trap "rm -f '${out}'" RETURN
  # --retry can send the request twice when the first landed and its answer
  # did not. The stage reads the newest evaluation of the commit, so a
  # second evaluation is tolerated; a dropped request is not.
  status="$(curl -sS --retry 5 --retry-connrefused --retry-delay 5 --max-time 30 \
    -A "${USER_AGENT}" \
    -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -H "Accept: application/json" \
    -o "${out}" -w '%{http_code}' -X POST "${url%/}/v1/evaluations/runs" --data-binary "${payload}")" || {
      echo "Could not reach ${url} at all." >&2
      return 1
    }
  if [ "${status}" -ge 200 ] && [ "${status}" -lt 300 ]; then
    jq -r '.data.message_id // ""' "${out}" 2> /dev/null || echo ""
    return 0
  fi
  # An HTML page means the request never reached the API: a 403 from the
  # edge and a 403 from authorization are different problems.
  if grep -qiE 'error code: 10|<!doctype html|just a moment|cloudflare|cf_chl' "${out}"; then
    echo "Blocked at the edge with ${status} before reaching the API (an HTML page, not JSON): check the WAF and the User-Agent." >&2
    return 1
  fi
  echo "The API refused the request with ${status}: $(jq -c '.error // .detail // .' "${out}" 2> /dev/null || head -c 500 "${out}")" >&2
  return 1
}

decide() {
  [ "$#" -eq 1 ] || usage
  local file="$1" state blocking ids rest
  if ! state="$(jq -er '.data.state | select(. == "pending" or . == "running" or . == "complete")' "${file}" 2> /dev/null)"; then
    echo pending
    echo "The answer could not be read as an outcome: $(head -c 200 "${file}" 2> /dev/null | tr '\n' ' ')"
    return 0
  fi
  blocking="$(jq -r --argjson b "${BLOCKING}" '[.data.counts // {} | to_entries[] | select(.key as $k | $b | index($k)) | .value] | add // 0' "${file}")"
  rest="$(jq -r '.data.counts // {} | "\(.WARN // 0) WARN, \(.INFO // 0) INFO"' "${file}")"
  if [ "${blocking}" -gt 0 ]; then
    ids="$(jq -r --argjson b "${BLOCKING}" '[.data.findings // [] | .[] | select(.severity as $s | $b | index($s)) | "\(.severity) \(.violation_id // "status"): \(.finding)"] | .[:3] | join("; ") | gsub("[\\r\\n]+"; " ")' "${file}")"
    echo blocked
    echo "${blocking} blocking finding(s) (${state}): ${ids:-none listed}"
    return 0
  fi
  case "${state}" in
    complete)
      echo pass
      echo "Complete with no CRITICAL or ERROR finding (${rest})." ;;
    running)
      echo pending
      echo "Findings are arriving (${rest}), and nothing says they are all of them yet." ;;
    *)
      echo pending
      echo "No finding of this evaluation has arrived yet." ;;
  esac
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
  [ "$#" -eq 7 ] || usage
  local timeout="$1" initial="$2" max="$3" repo="$4" sha="$5" phase="$6" since="$7"
  local url="${EVALUATE_API_URL:-}"
  if ! is_count "${timeout}" || ! is_count "${initial}" || ! is_count "${max}"; then
    echo "poll: timeout, initial and max are whole seconds" >&2
    return 2
  fi
  [ -n "${url}" ] || { echo "poll: EVALUATE_API_URL is not set" >&2; return 2; }
  local answer
  answer="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: the path is local to this call
  trap "rm -f '${answer}'" RETURN

  local start attempt=0 status out verdict reason="" run_id="" wait elapsed
  start="$(date +%s)"
  while :; do
    attempt=$(( attempt + 1 ))
    # Public and read-only, like GET /v1/evaluations: no key is sent.
    if status="$(curl -sS --max-time "${EVALUATE_REQUEST_SECONDS:-30}" -A "${USER_AGENT}" -H "Accept: application/json" \
        -o "${answer}" -w '%{http_code}' --get "${url%/}/v1/evaluations/runs/outcome" \
        --data-urlencode "repo=${repo}" --data-urlencode "sha=${sha}" --data-urlencode "phase=${phase}" \
        --data-urlencode "mode=deterministic" --data-urlencode "since=${since}" 2>&1)"; then :; else status="000 ${status}"; fi
    [ -n "${EVALUATE_ANSWER_FILE:-}" ] && cp "${answer}" "${EVALUATE_ANSWER_FILE}" 2> /dev/null || true
    case "${status}" in
      200)
        out="$(decide "${answer}")"
        verdict="$(sed -n 1p <<< "${out}")"
        reason="$(sed -n 2p <<< "${out}")"
        run_id="$(jq -r '.data.run_id // ""' "${answer}" 2> /dev/null || echo "")" ;;
      404)
        echo unsupported
        echo ""
        echo "${url} has no GET /v1/evaluations/runs/outcome: the API this stage needs is not deployed there."
        return 4 ;;
      *)
        verdict=pending
        reason="The API did not answer the outcome (${status:0:200})." ;;
    esac
    echo "attempt ${attempt}: ${verdict}: ${reason}" >&2
    case "${verdict}" in
      pass)
        echo pass; echo "${run_id}"; echo "${reason} (attempt ${attempt})"
        return 0 ;;
      blocked)
        echo blocked; echo "${run_id}"; echo "${reason}"
        return 1 ;;
    esac
    wait="$(delay "${attempt}" "${initial}" "${max}")"
    elapsed=$(( $(date +%s) - start ))
    if [ $(( elapsed + wait )) -gt "${timeout}" ]; then
      echo timeout
      echo "${run_id}"
      echo "No decision after ${elapsed}s and ${attempt} attempt(s): ${reason}"
      return 3
    fi
    sleep "${wait}"
  done
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift
case "${cmd}" in
  body) body "$@" ;;
  request) request "$@" ;;
  decide) decide "$@" ;;
  delay) delay "$@" ;;
  poll) poll "$@" ;;
  *) usage ;;
esac

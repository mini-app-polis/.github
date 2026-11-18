#!/usr/bin/env bash
# Proves the verify stage's decisions (verify-decision.sh): which versions
# count as the release, how a report compares, the backoff, and the poll
# that verifies on a match and times out on anything else. Then proves the
# probes (probe.sh) that read without side effects against a local server
# standing in for each target, and a stub aws for the Lambda probe. Nothing
# here reaches a real target. Run by the self-test, and by hand:
#
#   bash scripts/test-verify-decision.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${here}/../.github/actions/verify-decision"
tool="${dir}/verify-decision.sh"
probe="${dir}/probe.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "${server_pid}" ] && kill "${server_pid}" 2> /dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

failures=0
pass() { echo "ok: $1"; }
fail() { echo "::error::$1"; failures=$((failures + 1)); }

# Expect a command's output (all of it) to be the given lines.
prints() {
  local what="$1" want="$2"; shift 2
  local got
  if ! got="$("$@" 2> "${work}/err")"; then
    fail "${what}: exited non-zero ($(cat "${work}/err"))"
    return
  fi
  [ "${got}" = "${want}" ] && pass "${what}" || fail "${what}: got '${got//$'\n'/|}', wanted '${want//$'\n'/|}'"
}
refuses() {
  local what="$1"; shift
  if "$@" > "${work}/out" 2> "${work}/err"; then fail "${what}: accepted"; else pass "${what}"; fi
}
first_line() { sed -n 1p; }

# ---- wants ---------------------------------------------------------------
prints "production: the release, the build and what the commit declares" \
  $'2.99.0\n2.98.1+g0123456789ab\n2.98.1' "${tool}" wants 2.99.0 2.98.1+g0123456789ab
prints "development: the build version and what it declares" \
  $'1.4.0+g0123456789ab\n1.4.0' "${tool}" wants 1.4.0+g0123456789ab 1.4.0+g0123456789ab
prints "no build version: the version alone" "1.4.0" "${tool}" wants 1.4.0
prints "a build that already carries the release: one value" "1.4.0" "${tool}" wants 1.4.0 1.4.0
refuses "wants needs a version" "${tool}" wants ""

# ---- compare -------------------------------------------------------------
prints "a wanted version matches" "match" bash -c '"$0" compare 1.4.0 1.4.0 1.3.2 | sed -n 1p' "${tool}"
prints "any wanted version matches" "match" bash -c '"$0" compare 1.3.2 1.4.0 1.3.2 | sed -n 1p' "${tool}"
prints "another version is a mismatch" "mismatch" bash -c '"$0" compare 1.3.1 1.4.0 1.3.2 | sed -n 1p' "${tool}"
prints "a prefix is not a match" "mismatch" bash -c '"$0" compare 1.4 1.4.0 | sed -n 1p' "${tool}"
prints "nothing reported is pending" "pending" bash -c '"$0" compare "" 1.4.0 | sed -n 1p' "${tool}"
reason="$("${tool}" compare 1.3.1 1.4.0 | sed -n 2p)"
[[ "${reason}" == *1.3.1* && "${reason}" == *1.4.0* ]] && pass "the reason names both versions" || fail "the reason was '${reason}'"
refuses "compare needs something to want" "${tool}" compare 1.4.0

# ---- delay ---------------------------------------------------------------
prints "the first wait is the initial" "5" "${tool}" delay 1 5 60
prints "it doubles" "20" "${tool}" delay 3 5 60
prints "it stops at the cap" "60" "${tool}" delay 9 5 60
prints "a cap below the initial wins" "3" "${tool}" delay 1 5 3
prints "a very late attempt stays at the cap" "60" "${tool}" delay 500 5 60
refuses "attempt 0" "${tool}" delay 0 5 60
refuses "a non-number" "${tool}" delay 1 five 60

# ---- poll ----------------------------------------------------------------
# A probe that reports a fixed value, or fails, or reports from a file that
# changes between attempts.
cat > "${work}/says.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1"
EOF
cat > "${work}/down.sh" <<'EOF'
#!/usr/bin/env bash
echo "connection refused" >&2
exit 7
EOF
cat > "${work}/later.sh" <<'EOF'
#!/usr/bin/env bash
# Not answering on the first attempt, the old version on the second, the
# new one from the third.
n="$(cat "$1" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "${n}" > "$1"
case "${n}" in 1) echo "starting" >&2; exit 1 ;; 2) echo "1.3.2" ;; *) echo "1.4.0" ;; esac
EOF
cat > "${work}/slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
echo 1.4.0
EOF
chmod +x "${work}"/*.sh

poll_out() { "${tool}" poll "$@" 2> /dev/null; }

out="$(poll_out 5 1 1 "1.4.0 1.3.2" -- "${work}/says.sh" 1.4.0)" && st=0 || st=$?
[ "${st}" = 0 ] && [ "$(first_line <<< "${out}")" = verified ] && [ "$(sed -n 2p <<< "${out}")" = 1.4.0 ] \
  && pass "a match verifies at once" || fail "a match: exit ${st}, '${out//$'\n'/|}'"

start=$(date +%s)
out="$(poll_out 3 1 1 "1.4.0" -- "${work}/says.sh" 1.3.2)" && st=0 || st=$?
took=$(( $(date +%s) - start ))
[ "${st}" = 1 ] && [ "$(first_line <<< "${out}")" = timeout ] \
  && pass "a mismatch times out and fails" || fail "a mismatch: exit ${st}, '${out//$'\n'/|}'"
[ "$(sed -n 2p <<< "${out}")" = 1.3.2 ] && pass "the timeout keeps the last report" || fail "last report was '$(sed -n 2p <<< "${out}")'"
[[ "$(sed -n 3p <<< "${out}")" == *"Timed out"*1.3.2* ]] && pass "the timeout says why" || fail "timeout reason was '$(sed -n 3p <<< "${out}")'"
[ "${took}" -le 4 ] && pass "the timeout is kept (${took}s of 3)" || fail "the poll ran ${took}s past a 3s timeout"

out="$(poll_out 2 1 1 "1.4.0" -- "${work}/down.sh")" && st=0 || st=$?
[ "${st}" = 1 ] && [ "$(sed -n 2p <<< "${out}")" = "" ] && [[ "$(sed -n 3p <<< "${out}")" == *"connection refused"* ]] \
  && pass "a target that never answers times out with its error" || fail "never answering: exit ${st}, '${out//$'\n'/|}'"

out="$(poll_out 0 5 5 "1.4.0" -- "${work}/says.sh" 1.3.2)" && st=0 || st=$?
[ "${st}" = 1 ] && [[ "$(sed -n 3p <<< "${out}")" == *"1 attempt"* ]] \
  && pass "a zero timeout makes one attempt" || fail "zero timeout: exit ${st}, '${out//$'\n'/|}'"

rm -f "${work}/count"
out="$(poll_out 10 1 1 "1.4.0" -- "${work}/later.sh" "${work}/count")" && st=0 || st=$?
[ "${st}" = 0 ] && [[ "$(sed -n 3p <<< "${out}")" == *"attempt 3"* ]] \
  && pass "not answering, then the old version, then the new: verified on the third attempt" \
  || fail "later: exit ${st}, '${out//$'\n'/|}'"

start=$(date +%s)
out="$(VERIFY_PROBE_SECONDS=1 poll_out 1 1 1 "1.4.0" -- "${work}/slow.sh")" && st=0 || st=$?
took=$(( $(date +%s) - start ))
[ "${st}" = 1 ] && [ "${took}" -le 4 ] && pass "a hung probe is cut off (${took}s)" || fail "hung probe: exit ${st} after ${took}s"

refuses "poll needs the separator" "${tool}" poll 5 1 1 "1.4.0" "${work}/says.sh" 1.4.0
refuses "poll needs something to want" "${tool}" poll 5 1 1 "" -- "${work}/says.sh" 1.4.0
st=0; "${tool}" poll 5 1 1 "1.4.0" "${work}/says.sh" > /dev/null 2>&1 || st=$?
[ "${st}" = 2 ] && pass "a usage error is not a timeout (exit 2)" || fail "usage error exited ${st}"

# ---- probes, against a local stand-in --------------------------------------
# A directory served over HTTP: a path answers with the file of that name,
# and a missing file answers 404, as a target that does not have it would.
site="${work}/site"
mkdir -p "${site}/pypi/fixture-lib/1.4.0" "${site}/npm/@scope/pkg" "${site}/npm/plain" \
  "${site}/cf/accounts/acct/pages/projects/proj"
echo '{"status": "ok"}' > "${site}/health"
echo '{"status": "starting"}' > "${site}/health-starting"
echo '{"version": "1.4.0", "commit": null}' > "${site}/version"
echo '{"info": {"version": "1.4.0"}}' > "${site}/pypi/fixture-lib/1.4.0/json"
# http.server decodes %2f before it looks for the file.
echo '{"version": "1.4.0"}' > "${site}/npm/@scope/pkg/1.4.0"
echo '{"version": "2.0.0"}' > "${site}/npm/plain/2.0.0"
digest="sha256:$(printf '%064d' 0 | tr 0 a)"
other="sha256:$(printf '%064d' 0 | tr 0 b)"
jq -n --arg m "pipeline-deploy version=1.4.0 artifact=${digest}" \
  '{result: {canonical_deployment: {deployment_trigger: {metadata: {commit_message: $m}}}}}' \
  > "${site}/cf/accounts/acct/pages/projects/proj/index.html"
jq -n --arg m "pipeline-deploy version=1.4.0+g0123456789ab artifact=${digest}" \
  '{result: [
     {deployment_trigger: {metadata: {branch: "feature", commit_message: "x"}}, latest_stage: {name: "deploy", status: "success"}},
     {deployment_trigger: {metadata: {branch: "dev", commit_message: $m}}, latest_stage: {name: "deploy", status: "success"}}
   ]}' > "${site}/cf/accounts/acct/pages/projects/proj/deployments"

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${site}" > "${work}/server.log" 2>&1 &
server_pid=$!
base="http://127.0.0.1:${port}"
for _ in $(seq 1 50); do curl -s -o /dev/null "${base}/health" && break; sleep 0.1; done

prints "http: a healthy service reports its version" "1.4.0" \
  env VERIFY_URL="${base}/" VERIFY_HEALTH_PATH=/health VERIFY_VERSION_PATH=/version "${probe}" http
refuses "http: unhealthy is not an answer" \
  env VERIFY_URL="${base}" VERIFY_HEALTH_PATH=/health-starting VERIFY_VERSION_PATH=/version "${probe}" http
refuses "http: no health endpoint is not an answer" \
  env VERIFY_URL="${base}" VERIFY_HEALTH_PATH=/nothing VERIFY_VERSION_PATH=/version "${probe}" http
refuses "http: no version endpoint is not an answer" \
  env VERIFY_URL="${base}" VERIFY_HEALTH_PATH=/health VERIFY_VERSION_PATH=/nothing "${probe}" http
refuses "http: nothing listening is not an answer" \
  env VERIFY_URL="http://127.0.0.1:9" VERIFY_HEALTH_PATH=/health VERIFY_VERSION_PATH=/version "${probe}" http

prints "pypi: a published release resolves" "1.4.0" \
  env VERIFY_PYPI_URL="${base}" VERIFY_PACKAGE=fixture-lib VERIFY_VERSION=1.4.0 "${probe}" pypi
refuses "pypi: an unpublished release does not" \
  env VERIFY_PYPI_URL="${base}" VERIFY_PACKAGE=fixture-lib VERIFY_VERSION=1.5.0 "${probe}" pypi
prints "npm: a scoped package resolves" "1.4.0" \
  env VERIFY_REGISTRY="${base}/npm/" VERIFY_PACKAGE=@scope/pkg VERIFY_VERSION=1.4.0 "${probe}" npm
env VERIFY_REGISTRY="${base}/npm" VERIFY_PACKAGE=@scope/pkg VERIFY_VERSION=9.9.9 "${probe}" npm > /dev/null 2> "${work}/err" || true
grep -q '/npm/@scope%2fpkg/9.9.9' "${work}/err" && pass "npm: a scoped name's slash is escaped" || fail "npm: asked for $(cat "${work}/err")"
prints "npm: a plain package resolves" "2.0.0" \
  env VERIFY_REGISTRY="${base}/npm" VERIFY_PACKAGE=plain VERIFY_VERSION=2.0.0 "${probe}" npm
refuses "npm: an unpublished release does not" \
  env VERIFY_REGISTRY="${base}/npm" VERIFY_PACKAGE=plain VERIFY_VERSION=2.0.1 "${probe}" npm

pages() {
  env CLOUDFLARE_API_TOKEN=t VERIFY_CF_API="${base}/cf" VERIFY_CF_ACCOUNT=acct VERIFY_PAGES_PROJECT=proj \
    VERIFY_PAGES_DEV_BRANCH=dev VERIFY_URL="${base}/health" "$@" "${probe}" pages
}
# The project's own URL serves the canonical deployment; http.server serves
# the directory's index.html for it.
prints "pages: production reports the version the served upload carries" "1.4.0" \
  pages VERIFY_ENVIRONMENT=production VERIFY_ARTIFACT_DIGEST="${digest}"
prints "pages: development reads the newest upload of the dev branch" "1.4.0+g0123456789ab" \
  pages VERIFY_ENVIRONMENT=development VERIFY_ARTIFACT_DIGEST=
prints "pages: another artifact under the same version cannot match" "1.4.0 artifact=${digest}" \
  pages VERIFY_ENVIRONMENT=production VERIFY_ARTIFACT_DIGEST="${other}"
refuses "pages: a site that does not answer" \
  env CLOUDFLARE_API_TOKEN=t VERIFY_CF_API="${base}/cf" VERIFY_CF_ACCOUNT=acct VERIFY_PAGES_PROJECT=proj \
  VERIFY_ENVIRONMENT=production VERIFY_URL="${base}/nothing" "${probe}" pages
refuses "pages: a project with no upload of the pipeline's" \
  env CLOUDFLARE_API_TOKEN=t VERIFY_CF_API="${base}/cf" VERIFY_CF_ACCOUNT=acct VERIFY_PAGES_PROJECT=other \
  VERIFY_ENVIRONMENT=production VERIFY_URL="${base}/health" "${probe}" pages

# A stub aws on the PATH, answering as get-function-configuration does with
# --output text.
mkdir -p "${work}/bin"
cat > "${work}/bin/aws" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "lambda get-function-configuration" ] || { echo "unexpected: $*" >&2; exit 2; }
printf 'Active\tSuccessful\tabc123=\n'
EOF
chmod +x "${work}/bin/aws"
prints "lambda: state, last update and code checksum" "Active/Successful:abc123=" \
  env PATH="${work}/bin:${PATH}" VERIFY_FUNCTION=fn "${probe}" lambda

refuses "an unknown kind" "${probe}" ftp

if [ "${failures}" -ne 0 ]; then
  echo "::error::${failures} verify decision case(s) failed."
  exit 1
fi
echo "Every verify decision case passed."

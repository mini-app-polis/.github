#!/usr/bin/env bash
# What a target reports, for verify-decision.sh's poll: one probe per kind
# of target, reading only. Each prints what the target reports on its first
# line and exits 0, or exits non-zero with the reason on stderr when the
# target has no answer yet. Inputs come from the environment, so no value
# is ever spliced into a command line.
#
#   http     A service (Railway, or the self-test's stand-in). It must
#            answer VERIFY_URL + VERIFY_HEALTH_PATH with {"status": "ok"}
#            (the fleet's liveness probe, which touches no dependency), and
#            the probe prints .version from VERIFY_URL + VERIFY_VERSION_PATH.
#   pages    A Cloudflare Pages site. The site at VERIFY_URL must answer,
#            and the probe prints the version from the deployment the
#            project serves in VERIFY_ENVIRONMENT, read from its upload
#            message (pipeline-deploy version=<v> artifact=<digest>), as the
#            deploy stage reads it. When VERIFY_ARTIFACT_DIGEST is set and
#            the deployment holds another artifact, it prints that too, so
#            it cannot match. Needs CLOUDFLARE_API_TOKEN, VERIFY_CF_ACCOUNT,
#            VERIFY_PAGES_PROJECT and VERIFY_PAGES_DEV_BRANCH.
#   lambda   An AWS Lambda function, VERIFY_FUNCTION, with the credentials
#            in the environment. Prints <State>/<LastUpdateStatus>:<CodeSha256>.
#   pypi     The package VERIFY_PACKAGE at VERIFY_VERSION on PyPI
#            (VERIFY_PYPI_URL, default https://pypi.org). Prints the version
#            PyPI has under that release.
#   npm      The same on the npm registry (VERIFY_REGISTRY, default
#            https://registry.npmjs.org).
#
# VERIFY_CF_API overrides the Cloudflare API's base, for the tests.
set -euo pipefail

get() {
  # Bounded and quiet; the caller decides what a failure means.
  curl -sS --fail --location --max-time 15 "$@"
}

kind="${1:-}"
case "${kind}" in
  http)
    url="${VERIFY_URL%/}"
    if ! health="$(get "${url}${VERIFY_HEALTH_PATH:-/health}" 2>&1)"; then
      echo "${url}${VERIFY_HEALTH_PATH:-/health} did not answer: ${health}" >&2
      exit 1
    fi
    if ! jq -e '.status == "ok"' <<< "${health}" > /dev/null 2>&1; then
      echo "${url}${VERIFY_HEALTH_PATH:-/health} answered '${health:0:200}', not {\"status\": \"ok\"}" >&2
      exit 1
    fi
    if ! body="$(get "${url}${VERIFY_VERSION_PATH:-/version}" 2>&1)"; then
      echo "${url}${VERIFY_VERSION_PATH:-/version} did not answer: ${body}" >&2
      exit 1
    fi
    jq -r '.version // empty' <<< "${body}" 2> /dev/null || {
      echo "${url}${VERIFY_VERSION_PATH:-/version} answered '${body:0:200}', not JSON with a version" >&2
      exit 1
    } ;;

  pages)
    if ! site="$(get -o /dev/null "${VERIFY_URL}" 2>&1)"; then
      echo "${VERIFY_URL} did not answer: ${site}" >&2
      exit 1
    fi
    api="${VERIFY_CF_API:-https://api.cloudflare.com/client/v4}/accounts/${VERIFY_CF_ACCOUNT}/pages/projects/${VERIFY_PAGES_PROJECT}"
    auth=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
    if [ "${VERIFY_ENVIRONMENT}" = production ]; then
      if ! body="$(get "${auth[@]}" "${api}" 2>&1)"; then
        echo "Cloudflare did not answer for ${VERIFY_PAGES_PROJECT}: ${body:0:300}" >&2
        exit 1
      fi
      deployment="$(jq -c '.result.canonical_deployment // empty' <<< "${body}")"
    else
      if ! body="$(get "${auth[@]}" "${api}/deployments?env=preview&per_page=25" 2>&1)"; then
        echo "Cloudflare did not answer for ${VERIFY_PAGES_PROJECT}: ${body:0:300}" >&2
        exit 1
      fi
      deployment="$(jq -c --arg b "${VERIFY_PAGES_DEV_BRANCH:-dev}" \
        '[.result[] | select(.deployment_trigger.metadata.branch == $b and .latest_stage.name == "deploy" and .latest_stage.status == "success")][0] // empty' <<< "${body}")"
    fi
    message="$(jq -r '.deployment_trigger.metadata.commit_message // empty' <<< "${deployment:-null}")"
    if [[ "${message}" =~ ^pipeline-deploy\ version=([^ ]+)\ artifact=(sha256:[0-9a-f]{64})$ ]]; then
      if [ -n "${VERIFY_ARTIFACT_DIGEST:-}" ] && [ "${BASH_REMATCH[2]}" != "${VERIFY_ARTIFACT_DIGEST}" ]; then
        echo "${BASH_REMATCH[1]} artifact=${BASH_REMATCH[2]}"
      else
        echo "${BASH_REMATCH[1]}"
      fi
    else
      echo "${VERIFY_PAGES_PROJECT} serves no deployment of the pipeline's (message '${message}')" >&2
      exit 1
    fi ;;

  lambda)
    out="$(aws lambda get-function-configuration --function-name "${VERIFY_FUNCTION}" \
      --query '[State, LastUpdateStatus, CodeSha256]' --output text)"
    read -r state status sha <<< "${out}"
    echo "${state}/${status}:${sha}" ;;

  pypi)
    url="${VERIFY_PYPI_URL:-https://pypi.org}/pypi/${VERIFY_PACKAGE}/${VERIFY_VERSION}/json"
    if ! body="$(get "${url}" 2>&1)"; then
      echo "${url} did not answer: ${body:0:300}" >&2
      exit 1
    fi
    jq -r '.info.version // empty' <<< "${body}" ;;

  npm)
    # A scoped name keeps its @ and escapes its slash, as the registry wants.
    name="${VERIFY_PACKAGE/\//%2f}"
    url="${VERIFY_REGISTRY:-https://registry.npmjs.org}"
    url="${url%/}/${name}/${VERIFY_VERSION}"
    if ! body="$(get "${url}" 2>&1)"; then
      echo "${url} did not answer: ${body:0:300}" >&2
      exit 1
    fi
    jq -r '.version // empty' <<< "${body}" ;;

  *)
    echo "usage: $0 http|pages|lambda|pypi|npm" >&2
    exit 2 ;;
esac

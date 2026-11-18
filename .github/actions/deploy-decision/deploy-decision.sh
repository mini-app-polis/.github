#!/usr/bin/env bash
# The deploy stage's two decisions, kept out of the workflow so they can be
# tested on their own (scripts/test-deploy-decision.sh):
#
#   guard <environment> <target> <ref> <version>
#       Whether this run may deploy to that environment at all. Fails with
#       the reason when it may not.
#         - environment is development or production; target is live or
#           fake (fake is the self-test's stand-in, which deploys nowhere).
#         - production deploys a release: version is X.Y.Z, nothing more.
#         - a live production deploy runs from main, a live development
#           deploy from dev. A fake one may run from any ref, so the
#           self-test exercises both environments on every pull request.
#
#   decide <wanted-version> <wanted-id> <running-version> <running-id>
#       Whether to deploy, given what the target already runs. Prints
#       "deploy" or "skip" on the first line and the reason on the second.
#         wanted-version   the version this run deploys (required)
#         wanted-id        what identifies the artifact on the target: the
#                          image's config digest, the Lambda zip's
#                          CodeSha256, the artifact digest (required)
#         running-version  the version the target says it runs; empty when
#                          the target records none (a Lambda function) or
#                          runs nothing yet
#         running-id       the same identity read from the target; empty
#                          when it runs nothing yet or cannot say
#       The target already runs this version when it reports the same
#       version, or, for a target that records no version, the same
#       artifact. The same version with other bytes is still skipped (a
#       re-run in a new run may rebuild the same commit) and says so.
set -euo pipefail

usage() {
  echo "usage: $0 guard <environment> <target> <ref> <version>" >&2
  echo "       $0 decide <wanted-version> <wanted-id> <running-version> <running-id>" >&2
  exit 2
}

guard() {
  local environment="$1" target="$2" ref="$3" version="$4"
  case "${environment}" in
    development|production) ;;
    *) echo "environment is '${environment}': it is development or production." >&2; return 1 ;;
  esac
  case "${target}" in
    live|fake) ;;
    *) echo "target is '${target}': it is live or fake." >&2; return 1 ;;
  esac
  if [ -z "${version}" ]; then
    echo "No version to deploy." >&2
    return 1
  fi
  if [ "${environment}" = production ] && ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Production deploys a release, X.Y.Z; '${version}' is not one." >&2
    return 1
  fi
  if [ "${target}" = live ]; then
    if [ "${environment}" = production ] && [ "${ref}" != refs/heads/main ]; then
      echo "Production deploys from main only; this run is on '${ref}'." >&2
      return 1
    fi
    if [ "${environment}" = development ] && [ "${ref}" != refs/heads/dev ]; then
      echo "Development deploys from dev only; this run is on '${ref}'." >&2
      return 1
    fi
  fi
  echo "${environment} may take ${version} from ${ref} (${target} target)."
}

decide() {
  local wanted_version="$1" wanted_id="$2" running_version="$3" running_id="$4"
  if [ -z "${wanted_version}" ] || [ -z "${wanted_id}" ]; then
    echo "decide needs the version and the identity of what is deployed." >&2
    return 1
  fi
  if [ -n "${running_version}" ] && [ "${running_version}" = "${wanted_version}" ]; then
    echo skip
    if [ -n "${running_id}" ] && [ "${running_id}" != "${wanted_id}" ]; then
      echo "The target already runs ${wanted_version}, from another build of it (${running_id}, not ${wanted_id}); it is not deployed again."
    else
      echo "The target already runs ${wanted_version}."
    fi
    return 0
  fi
  if [ -z "${running_version}" ] && [ -n "${running_id}" ] && [ "${running_id}" = "${wanted_id}" ]; then
    echo skip
    echo "The target already runs this artifact (${wanted_id}), so it runs ${wanted_version}."
    return 0
  fi
  echo deploy
  if [ -z "${running_version}${running_id}" ]; then
    echo "The target reports nothing deployed by the pipeline yet."
  else
    echo "The target runs ${running_version:-an unrecorded version} (${running_id:-unknown}), not ${wanted_version} (${wanted_id})."
  fi
}

[ "$#" -ge 1 ] || usage
command="$1"; shift
case "${command}" in
  guard) [ "$#" -eq 4 ] || usage; guard "$@" ;;
  decide) [ "$#" -eq 4 ] || usage; decide "$@" ;;
  *) usage ;;
esac

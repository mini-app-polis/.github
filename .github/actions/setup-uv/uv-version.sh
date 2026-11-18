#!/usr/bin/env bash
# Prints the uv release the pipeline installs: `uv_version` in pipeline.yaml
# at the root of this repository. The value lives only there; this action
# and python-checks both read it through this script, so a move of the pin
# is one line in one file.
#
# It finds pipeline.yaml from its own location rather than the workspace:
# when a caller in another repository runs one of this repository's
# actions, the runner fetches this whole repository at the action's ref,
# and that copy, not the caller's checkout, holds the pin.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${here}/../../../pipeline.yaml"

if [ ! -f "${file}" ]; then
  echo "::error::pipeline.yaml not found beside this action, at ${file}." >&2
  exit 1
fi

version="$(sed -n -E 's/^uv_version:[[:space:]]*"?([0-9][0-9A-Za-z.+-]*)"?[[:space:]]*(#.*)?$/\1/p' "${file}")"
if [ -z "${version}" ]; then
  echo "::error::pipeline.yaml has no uv_version." >&2
  exit 1
fi
echo "${version}"

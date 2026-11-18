#!/usr/bin/env bash
#
# This repository's successCmd (.releaserc.json): move the major tag onto the
# release semantic-release just cut. The work, and why, is in the release
# action's own copy, which its finish step also runs on a re-run.
#
# Usage: move-major-tag.sh <x.y.z>
set -euo pipefail
exec bash "$(dirname "$0")/../.github/actions/semantic-release/move-major-tag.sh" "$@"

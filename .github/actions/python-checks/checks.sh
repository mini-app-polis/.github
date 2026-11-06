#!/usr/bin/env bash
# The test stage's checks, run in order from the repository root, stopping
# at the first that fails. action.yml beside this file runs it; --print
# lists the commands instead, one per line.
#
# Environment: PYTHON_VERSION, PYTEST_ARGS, TYPECHECK (may be empty),
# TF_DIR (may be empty), and LOG, the file every check's output is also
# written to.
set -uo pipefail

checks=(
  # CD-020. `uv sync` without --locked silently re-resolves when the
  # lockfile and pyproject.toml disagree, so a stale lock passes CI and
  # then ships something else. Checked here because this is where the
  # failure is cheap to fix, and the deploy builds from this same lock.
  "uv lock --check"
  "uv sync --locked --all-extras --python ${PYTHON_VERSION}"
  "uv run ruff check"
  "uv run ruff format --check"
)
if [ -n "${TYPECHECK}" ]; then
  checks+=("${TYPECHECK}")
fi
if [ -n "${TF_DIR}" ]; then
  # -backend=false: validate needs the providers' schemas, not state. The
  # committed .terraform.lock.hcl pins the versions. Not -lockfile=readonly:
  # the lock is written on a Mac, and init has to add the Linux hash to the
  # runner's copy for validate to pass; the versions are still the lock's.
  checks+=(
    "terraform -chdir=${TF_DIR} fmt -check -recursive -diff"
    "terraform -chdir=${TF_DIR} init -backend=false -input=false"
    "terraform -chdir=${TF_DIR} validate"
  )
fi
checks+=("uv run pytest ${PYTEST_ARGS}")
if [ -f facts.yaml ]; then
  # A repo that publishes the figures it owns keeps facts.json in step with
  # its data. Run from the latest miniapppolis-common-utils, so it needs no
  # dependency in the repo.
  checks+=("uvx --from miniapppolis-common-utils facts check")
fi

if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "${checks[@]}"
  exit 0
fi

if [ -z "${TYPECHECK}" ]; then
  echo "::warning title=TEST-012::No typecheck input was passed, so nothing typechecked this run."
fi

: > "${LOG}"
for check in "${checks[@]}"; do
  echo "::group::${check}"
  printf '$ %s\n' "${check}" >> "${LOG}"
  bash -c "${check}" 2>&1 | tee -a "${LOG}"
  status=${PIPESTATUS[0]}
  echo "::endgroup::"
  if [ "${status}" -ne 0 ]; then
    echo "::error::check failed: ${check}"
    printf 'FAILED (exit %s): %s\n' "${status}" "${check}" >> "${LOG}"
    exit "${status}"
  fi
done

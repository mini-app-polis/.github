#!/usr/bin/env bash
# The steps of the lambda-zip action that are shell, one subcommand each so
# the action can put QEMU between the glibc guard and the runtime guard.
# Everything comes in through the environment the action sets; see its
# header for what each guard is for.
#
#   lambda-zip.sh resolve   validate the target, write its parameters to $GITHUB_OUTPUT
#   lambda-zip.sh build     install the locked dependencies and the project into $BUILD (guard 1)
#   lambda-zip.sh glibc     fail if a compiled library needs a newer glibc than the runtime (guard 2)
#   lambda-zip.sh probe     import every module and probe the handler in Lambda's image (guard 3)
#   lambda-zip.sh package   zip $BUILD into $OUT/worker.zip, with target.json beside it
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  resolve)
    echo "lambda-zip: ${HANDLER} on python${PY}/${ARCH}"
    case "${ARCH}" in
      x86_64) wheel_arch=x86_64; platform=linux/amd64 ;;
      arm64) wheel_arch=aarch64; platform=linux/arm64 ;;
      *) echo "::error::architecture must be x86_64 or arm64, got '${ARCH}'"; exit 1 ;;
    esac
    case "${TRIGGER}" in
      sqs|schedule) ;;
      *) echo "::error::trigger must be sqs or schedule, got '${TRIGGER}'"; exit 1 ;;
    esac
    # The runtime's glibc, by Python version. python3.8 to 3.11 run on
    # Amazon Linux 2 (glibc 2.26); 3.12 onward on Amazon Linux 2023
    # (glibc 2.34). Wheels are chosen at the matching manylinux tag.
    case "${PY}" in
      3.8|3.9|3.10|3.11) glibc_minor=26; manylinux=manylinux_2_17 ;;
      3.12|3.13|3.14) glibc_minor=34; manylinux=manylinux_2_28 ;;
      *) echo "::error::no known Lambda runtime for python ${PY}"; exit 1 ;;
    esac
    if ! [[ "${HANDLER}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]]; then
      echo "::error::handler must be module.path.function, got '${HANDLER}'"
      exit 1
    fi
    module="${HANDLER%.*}"
    {
      echo "wheel-arch=${wheel_arch}"
      echo "docker-platform=${platform}"
      echo "glibc-minor=${glibc_minor}"
      echo "manylinux=${manylinux}"
      echo "module=${module}"
      echo "func=${HANDLER##*.}"
      echo "module-path=${module//.//}.py"
      echo "package=${module%%.*}"
    } >> "${GITHUB_OUTPUT}"
    ;;

  build)
    rm -rf "${BUILD}"
    mkdir -p "${BUILD}"
    requirements="$(dirname "${BUILD}")/requirements.lock.txt"
    # From the lockfile, not a fresh resolve: the zip carries exactly the
    # versions the test stages ran against (CD-020).
    uv export --frozen --no-dev --no-emit-project --no-hashes \
      --format requirements-txt -o "${requirements}"

    # Guard 1. Left to itself uv picks the newest wheel the *runner* can
    # load, for the runner's architecture.
    uv pip install --python "${PY}" \
      --python-platform "${WHEEL_ARCH}-${MANYLINUX}" \
      --target "${BUILD}" -r "${requirements}" --quiet
    uv pip install --python "${PY}" --target "${BUILD}" --no-deps . --quiet

    rm -rf "${BUILD}/boto3" "${BUILD}/botocore" "${BUILD}/s3transfer" "${BUILD}/jmespath"
    for path in ${STRIP}; do rm -rf "${BUILD:?}/${path}"; done
    # dist-info stays. It is metadata, not dead weight: packages read their
    # own version from it at import (httpx2, under anthropic and openai,
    # does `importlib.metadata.version("httpx2")` and fails to import
    # without it), the run-report library stamps each report with the
    # cog's version the same way, and the SBOM reads it.
    rm -rf "${BUILD}/__pycache__"

    if [ ! -f "${BUILD}/${MODULE_PATH}" ]; then
      echo "::error::${MODULE_PATH} is not at the zip root; the handler cannot resolve"
      exit 1
    fi
    ;;

  glibc)
    worst=$(find "${BUILD}" -name '*.so*' -type f -exec readelf -V {} + 2>/dev/null \
      | grep -o 'GLIBC_2\.[0-9]*' | sort -t. -k2 -n -u | tail -1 || true)
    echo "newest glibc symbol required: ${worst:-none}; runtime has GLIBC_2.${GLIBC_MINOR}"
    if [ -n "${worst}" ] && [ "${worst#GLIBC_2.}" -gt "${GLIBC_MINOR}" ]; then
      echo "::error::the zip needs ${worst}; the runtime has GLIBC_2.${GLIBC_MINOR}"
      find "${BUILD}" -name '*.so*' -type f | while read -r f; do
        if readelf -V "${f}" 2>/dev/null | grep -q "${worst}"; then echo "  ${f}"; fi
      done
      exit 1
    fi
    ;;

  probe)
    docker run --rm -i --platform "${DOCKER_PLATFORM}" \
      -v "${BUILD}:/var/task:ro" -e PYTHONPATH=/var/task \
      -e PACKAGE -e MODULE -e FUNC -e TRIGGER \
      --entrypoint /var/lang/bin/python3 \
      "public.ecr.aws/lambda/python:${PY}" - < "${here}/probe.py"
    ;;

  package)
    mkdir -p "${OUT}"
    rm -f "${OUT}/worker.zip"
    (cd "${BUILD}" && zip -qr "${OUT}/worker.zip" .)
    size=$(stat -c%s "${OUT}/worker.zip")
    echo "zip is $((size / 1024 / 1024)) MB of the 50 MB direct-upload limit"
    if [ "${size}" -gt 47000000 ]; then
      echo "::error::the zip is within 3 MB of the 50 MB limit"
      exit 1
    fi
    # What the zip was built for, so a deploy that takes it from the build
    # stage can refuse a function it was not built for.
    jq -n --arg handler "${HANDLER}" --arg architecture "${ARCH}" \
      --arg python "${PY}" --arg trigger "${TRIGGER}" \
      '{handler: $handler, architecture: $architecture, "python-version": $python, trigger: $trigger}' \
      > "${OUT}/target.json"
    {
      echo "zip=${OUT}/worker.zip"
      echo "sha256=$(sha256sum "${OUT}/worker.zip" | cut -d' ' -f1)"
      # The form Lambda reports as CodeSha256.
      echo "code-sha256=$(openssl dgst -sha256 -binary "${OUT}/worker.zip" | base64)"
    } >> "${GITHUB_OUTPUT}"
    ;;

  *)
    echo "usage: $0 resolve|build|glibc|probe|package" >&2
    exit 2
    ;;
esac

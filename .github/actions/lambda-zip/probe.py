# Guard 3, run inside public.ecr.aws/lambda/python:<version> with the zip's
# contents at /var/task. A pass means the function will start; an import
# check on the runner does not.
import importlib
import os
import pkgutil
import platform
import sys

print(f"runtime: python {platform.python_version()} on {platform.machine()}")
package = importlib.import_module(os.environ["PACKAGE"])
failed = []
for m in pkgutil.walk_packages(package.__path__, package.__name__ + "."):
    try:
        importlib.import_module(m.name)
    except Exception as exc:
        failed.append(f"{m.name}: {type(exc).__name__}: {exc}")
if failed:
    print("::error::the package does not import in the Lambda runtime")
    for line in failed:
        print(f"  {line}")
    sys.exit(1)

handler = getattr(importlib.import_module(os.environ["MODULE"]), os.environ["FUNC"])
if not callable(handler):
    print(f"::error::{os.environ['MODULE']}.{os.environ['FUNC']} is not callable")
    sys.exit(1)

# A scheduled function's event carries nothing to probe, and calling it
# would run a real tick with no configuration.
if os.environ["TRIGGER"] == "schedule":
    print("every module imports, and the handler resolves, in the Lambda runtime")
    sys.exit(0)

# The probe from each cog's infra runbook, without AWS: a malformed record
# must come back as a reported failure (the batchItemFailures shape the
# event source mapping acts on) and not as an exception, which would fail
# the whole batch.
record = {"messageId": "probe-1", "body": "not json", "attributes": {}}
result = handler({"Records": [record]}, None)
expected = {"batchItemFailures": [{"itemIdentifier": "probe-1"}]}
if result != expected:
    print(f"::error::probe returned {result!r}, expected {expected!r}")
    sys.exit(1)
print("every module imports, and the handler answers, in the Lambda runtime")

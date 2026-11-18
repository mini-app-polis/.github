"""The fixture's Lambda handler: answers with the version it runs."""

from typing import Any

VERSION = "0.0.0"


def lambda_handler(event: dict[str, Any], context: object) -> dict[str, Any]:
    records = len(event.get("Records", []))
    return {"status": "ok", "version": VERSION, "records": records}

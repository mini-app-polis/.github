"""The fixture's health endpoint body: reports the version the service runs."""

VERSION = "0.0.0"


def health() -> dict[str, str]:
    return {"status": "ok", "version": VERSION}

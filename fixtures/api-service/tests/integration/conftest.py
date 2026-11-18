"""The database the integration stage gives this fixture.

The stage starts a Postgres service container and exports its address as
TEST_DATABASE_URL and DATABASE_URL, the names the fleet's own suites read.
A missing address fails rather than skips: a suite that skipped here would
pass whether or not the container was there, which is what this test is
for. The address must be local and the database named *_test, as the
fleet's suites require before they touch one.
"""

from __future__ import annotations

import os
from urllib.parse import urlparse

import pytest


@pytest.fixture(scope="session")
def database_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL", "")
    if not url:
        pytest.fail(
            "TEST_DATABASE_URL is not set; the integration stage exports it "
            "when it starts a Postgres service container."
        )
    parsed = urlparse(url)
    if parsed.hostname not in {"localhost", "127.0.0.1"} or not parsed.path.endswith(
        "_test"
    ):
        pytest.fail(
            f"Refusing {parsed.hostname}{parsed.path}: not local or not *_test."
        )
    return url

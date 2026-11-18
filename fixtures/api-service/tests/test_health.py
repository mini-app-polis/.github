from fixture_api_service.health import VERSION, health


def test_health_reports_the_running_version() -> None:
    assert health() == {"status": "ok", "version": VERSION}

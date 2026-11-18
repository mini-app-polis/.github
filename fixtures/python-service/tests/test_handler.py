from fixture_python_service.handler import VERSION, lambda_handler


def test_handler_reports_its_version() -> None:
    assert lambda_handler({"Records": [{}, {}]}, None) == {
        "status": "ok",
        "version": VERSION,
        "records": 2,
    }

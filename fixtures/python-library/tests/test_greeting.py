from fixture_python_library.greeting import greeting


def test_greeting() -> None:
    assert greeting("fleet") == "Hello, fleet."

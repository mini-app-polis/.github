# The api-service fixture's image, built by the build stage and saved to a
# tarball in the run's artifact. It is never pushed or run.
FROM python:3.14-slim

WORKDIR /app
COPY src/ ./src/
ENV PYTHONPATH=/app/src

USER nobody
CMD ["python", "-c", "from fixture_api_service.health import health; print(health())"]

"""A stand-in for the two routes the evaluation stages call, for tests only.

The self-test's `target: fake` and scripts/test-evaluate-decision.sh run
the stages against this on the job's loopback, so no fixture ever reaches
the real API. It answers as api-kaianolevine-com does:

  POST /v1/evaluations/runs        202 with a message id, once the key is
                                   the stand-in's own and the body is what
                                   the API would accept from the stage
  GET  /v1/evaluations/runs/outcome  the outcome of what was asked for

and appends every request it gets to the record file, one JSON line each.

    python3 stand-in.py <port> <scenario> <record-file>

Scenarios, for what the outcome says once something was asked for:

  clean     pending, pending, then complete with the one SUCCESS row
  blocking  pending, then running with an ERROR finding
  running   running with a WARN finding, and never complete
  missing   no outcome route at all (404)
  refuse    the request itself is refused (403)

An outcome asked for a commit, repository or phase that was not requested,
or without `since`, stays pending: the stage must read back exactly what it
asked for.
"""

from __future__ import annotations

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

KEY = "fake-key"
PORT, SCENARIO, RECORD = int(sys.argv[1]), sys.argv[2], sys.argv[3]
asked: list[dict] = []
reads = 0


def outcome(query: dict[str, str]) -> dict:
    global reads
    counts = dict.fromkeys(("CRITICAL", "ERROR", "WARN", "INFO", "SUCCESS"), 0)
    base = {
        "repo": query.get("repo"),
        "sha": query.get("sha"),
        "phase": query.get("phase"),
        "mode": "deterministic",
        "state": "pending",
        "run_id": None,
        "counts": counts,
        "findings": [],
    }
    wanted = asked[-1] if asked else None
    if (
        wanted is None
        or not query.get("since")
        or any(query.get(k) != wanted.get(k) for k in ("repo", "sha", "phase"))
    ):
        return base
    reads += 1
    run = {"run_id": "deterministic-0.0.0-standin"}
    if SCENARIO == "clean" and reads >= 3:
        counts["SUCCESS"] = 1
        row = {"violation_id": None, "severity": "SUCCESS", "dimension": "structural_conformance",
               "finding": "passed all deterministic checks"}
        return {**base, **run, "state": "complete", "findings": [row]}
    if SCENARIO == "blocking" and reads >= 2:
        counts["ERROR"] = 1
        row = {"violation_id": "CD-026", "severity": "ERROR", "dimension": "cd_readiness",
               "finding": "the stand-in's planted ERROR"}
        return {**base, **run, "state": "running", "findings": [row]}
    if SCENARIO == "running":
        counts["WARN"] = 1
        row = {"violation_id": "CD-031", "severity": "WARN", "dimension": "cd_readiness",
               "finding": "the stand-in's WARN"}
        return {**base, **run, "state": "running", "findings": [row]}
    return base


def valid(body: dict) -> str:
    """What the API would refuse in the stage's request, or empty."""
    if body.get("mode") != "deterministic":
        return "mode must be deterministic"
    if body.get("phase") not in ("pre-release", "post-release"):
        return "phase must be pre-release or post-release"
    if not re.fullmatch(r"[0-9a-f]{40}", body.get("sha") or ""):
        return "sha must be the full commit sha"
    if not body.get("repo") or not body.get("org") or not body.get("ref"):
        return "repo, org and ref are required"
    return ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def answer(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, entry: dict) -> None:
        with open(RECORD, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        self.record({"method": "GET", "path": url.path, "query": query,
                     "auth": self.headers.get("Authorization")})
        if url.path == "/health":
            return self.answer(200, {"status": "ok"})
        if url.path != "/v1/evaluations/runs/outcome" or SCENARIO == "missing":
            return self.answer(404, {"detail": "Not Found"})
        self.answer(200, {"data": outcome(query)})

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        self.record({"method": "POST", "path": self.path, "body": body,
                     "auth": self.headers.get("Authorization")})
        if self.path != "/v1/evaluations/runs":
            return self.answer(404, {"detail": "Not Found"})
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            return self.answer(401, {"error": {"code": "unauthorized"}})
        if SCENARIO == "refuse":
            return self.answer(403, {"error": {"code": "forbidden", "message": "missing scope"}})
        problem = valid(body)
        if problem:
            return self.answer(422, {"error": {"code": "invalid", "message": problem}})
        asked.append(body)
        self.answer(202, {"data": {"accepted": True, "run_id": "",
                                   "message_id": f"standin-{len(asked)}",
                                   "repo": body["repo"], "ref": body["ref"], "mode": body["mode"],
                                   "sha": body["sha"], "phase": body["phase"]}})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

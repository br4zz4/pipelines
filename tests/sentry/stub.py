import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE, PORTFILE, REQLOG = sys.argv[1:4]
TOKEN = "Bearer tok"
ISSUES = re.compile(r"^/api/0/organizations/o/issues/$")
LATEST = re.compile(r"^/api/0/organizations/o/issues/([^/]+)/events/latest/$")
COMMENTS = re.compile(r"^/api/0/organizations/o/issues/([^/]+)/comments/$")


def read(name, default=None):
    path = os.path.join(STATE, name)
    if not os.path.exists(path):
        return default
    with open(path) as handle:
        return handle.read().strip()


def read_json(name, default):
    text = read(name)
    return default if text is None else json.loads(text)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, parsed, body):
        entry = {
            "method": self.command,
            "path": parsed.path,
            "query": parse_qs(parsed.query, keep_blank_values=True),
            "body": body,
            "auth": self.headers.get("Authorization"),
        }
        with open(REQLOG, "a") as handle:
            handle.write(json.dumps(entry) + "\n")

    def do_GET(self):
        parsed = urlparse(self.path)
        self.record(parsed, None)
        if self.headers.get("Authorization") != TOKEN:
            return self.reply(401, {"detail": "bad token"})
        query = parse_qs(parsed.query)
        if ISSUES.match(parsed.path):
            issues = read_json("issues.json", [])
            if query.get("sort") == ["freq"]:
                issues = sorted(issues, key=lambda item: int(item["count"]), reverse=True)
            return self.reply(200, issues)
        match = LATEST.match(parsed.path)
        if match:
            event = read_json("events/%s.json" % match.group(1), None)
            return self.reply(404, {"detail": "no event"}) if event is None else self.reply(200, event)
        match = COMMENTS.match(parsed.path)
        if match:
            status = int(read("comments_status", "200"))
            if status != 200:
                return self.reply(status, {"detail": "comments unavailable"})
            return self.reply(200, read_json("comments/%s.json" % match.group(1), []))
        return self.reply(404, {"detail": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw
        self.record(parsed, body)
        if self.headers.get("Authorization") != TOKEN:
            return self.reply(401, {"detail": "bad token"})
        if COMMENTS.match(parsed.path):
            status = int(read("post_status", "201"))
            if status >= 400:
                return self.reply(status, {"detail": "You do not have permission to perform this action."})
            return self.reply(status, {"id": "1", "type": "note", "data": {"text": body.get("text") if isinstance(body, dict) else None}})
        return self.reply(404, {"detail": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
tmp = PORTFILE + ".tmp"
with open(tmp, "w") as handle:
    handle.write(str(server.server_address[1]))
os.rename(tmp, PORTFILE)
server.serve_forever()

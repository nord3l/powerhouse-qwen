#!/usr/bin/env python3
"""A scripted OpenAI-compatible chat server for end-to-end tests of the opencode setup.

  mock-llm.py <port> <script.json> <log.jsonl>

script.json is a list of rules: {"match": "<substring of the request JSON>", "replies": [...]}.
Each request goes to the first rule whose match occurs in the request and that still has
replies left. A reply is {"text": "..."} or {"tool_calls": [{"name": ..., "arguments": {...}}]}.
Requests without tools (title generation) get a fixed title; requests no rule matches get "ok". Every request is appended to log.jsonl.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, SCRIPT, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
RULES = json.load(open(SCRIPT))
LOCK = threading.Lock()
COUNTER = [0]


def pick(body):
    if '"tools"' not in body:  # title and summary requests carry no tools
        return {"text": "Test session"}
    with LOCK:
        for rule in RULES:
            if rule["match"] in body and rule["replies"]:
                return rule["replies"].pop(0)
    return {"text": "ok"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"data": [{"id": "mock", "object": "model"}]}).encode())

    def chunk(self, delta, finish=None):
        payload = {"id": "c", "object": "chat.completion.chunk", "created": 0, "model": "mock",
                   "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        reply = pick(body)
        with LOCK:
            with open(LOG, "a") as f:
                f.write(json.dumps({"request": json.loads(body), "reply": reply}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.chunk({"role": "assistant"})
        if "tool_calls" in reply:
            for i, call in enumerate(reply["tool_calls"]):
                with LOCK:
                    COUNTER[0] += 1
                    cid = "call_%d" % COUNTER[0]
                self.chunk({"tool_calls": [{"index": i, "id": cid, "type": "function", "function": {
                    "name": call["name"], "arguments": json.dumps(call["arguments"])}}]})
            self.chunk({}, "tool_calls")
        else:
            self.chunk({"content": reply.get("text", "ok")})
            self.chunk({}, "stop")
        usage = {"id": "c", "object": "chat.completion.chunk", "created": 0, "model": "mock", "choices": [],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
        self.wfile.write(b"data: " + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

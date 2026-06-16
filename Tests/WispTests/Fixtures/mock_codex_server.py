#!/usr/bin/env python3
"""Wisp 테스트용 가짜 codex app-server (실측 프로토콜 모사).
MOCK_SCENARIO: ok | timeout | crash | crash_mid_turn"""
import sys, json, os, time

scenario = os.environ.get("MOCK_SCENARIO", "ok")

def reply(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    method, rid = req.get("method"), req.get("id")

    if rid is None:
        continue  # notifications (예: initialized) — 응답 없음

    if method == "initialize":
        reply({"jsonrpc": "2.0", "id": rid, "result": {"serverInfo": {"name": "mock"}}})
    elif method == "thread/start":
        if scenario == "crash":
            sys.exit(1)
        reply({"jsonrpc": "2.0", "id": rid, "result": {"thread": {"id": "t1"}}})
    elif method == "turn/start":
        reply({"jsonrpc": "2.0", "id": rid, "result": {"status": "inProgress"}})
        if scenario == "crash_mid_turn":
            sys.exit(1)  # 턴 도중 죽음 — notification 없음
        if scenario == "timeout":
            time.sleep(30)
        reply({"jsonrpc": "2.0", "method": "item/completed",
               "params": {"threadId": "t1",
                          "item": {"type": "agentMessage", "text": "다듬어진 텍스트"}}})
        reply({"jsonrpc": "2.0", "method": "turn/completed",
               "params": {"threadId": "t1", "turn": {"status": "completed", "items": []}}})
    else:
        reply({"jsonrpc": "2.0", "id": rid, "result": {}})

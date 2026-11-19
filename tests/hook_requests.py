"""Offline CLI checks for request hooks. Build synth, then run this with Python 3."""
from concurrent.futures import ThreadPoolExecutor
import contextlib
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import threading
import traceback
import time

BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "zig-out/bin/synth"


def chat(text="done", call=None):
    message = {"role": "assistant", "content": text}
    if call:
        message["tool_calls"] = [{"id": "test-call", "type": "function", "function": call}]
    return 200, {"choices": [{"message": message, "finish_reason": "tool_calls" if call else "stop"}]}, "application/json"


def tool(name, arguments):
    return {"name": name, "arguments": json.dumps(arguments)}


@contextlib.contextmanager
def session(name, respond, logic="", events=(), protocol="chat", attempts=2, extra_hooks=None, trust=True, route_policy=True, configure=None, on_show=None):
    requests = []
    errors = []

    class Server(http.server.ThreadingHTTPServer):
        def handle_error(self, *_):
            errors.append(traceback.format_exc())

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            assert self.path.endswith('/api/ps') or self.path == '/agent/v1/models', self.path
            body = json.dumps({'data': [{'id': 'agent-model'}]} if self.path.endswith('/models') else {'models': []}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path.endswith("/api/show"):
                value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert value["model"] in ("agent-model", "selected-model", "review-model")
                if on_show:
                    on_show(value)
                body = json.dumps({"capabilities": ["completion", "tools"], "model_info": {"llama.context_length": 16384}}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            packet = {"path": self.path, "headers": dict(self.headers), "raw_headers": list(self.headers.items()), "body": json.loads(self.rfile.read(int(self.headers["Content-Length"])))}
            suffix = "/api/chat" if protocol == "ollama" else "/v1/messages" if protocol == "messages" else "/v1/responses" if protocol == "responses" else "/v1/chat/completions"
            assert self.path in ("/agent" + suffix, "/selected" + suffix, "/review/v1/chat/completions", "/review/api/chat"), self.path
            if protocol == "ollama": assert packet["body"].get("think") is not True
            requests.append(packet)
            status, value, content_type = respond(packet, requests)
            body = value.encode() if isinstance(value, str) else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix=f"synth-{name}-") as directory:
            root = Path(directory).resolve()
            (root / ".git").mkdir()
            (root / ".synth").mkdir()
            (root / "home").mkdir()
            (root / "home/.bash_profile").write_text("echo unexpected-login-output\n")
            (root / "seed.txt").write_text("seed data")
            url = f"http://127.0.0.1:{server.server_port}"
            routes = [{"id": identifier, "provider": "ollama" if protocol == "ollama" and identifier != "review" else "openai", "endpoint": f"{url}/{identifier}" + ("" if protocol == "ollama" and identifier != "review" else "/v1"), "model": f"{identifier}-model", "protocol": "chat" if protocol == "ollama" or identifier == "review" else protocol, "context_limit": 16384, "api_key": f"{identifier}-secret", "purposes": ["approval_judge"] if identifier == "review" else ["agent", "compaction"], "settings": {"attempts": attempts, "retry_delay_ms": 0}} for identifier in ("agent", "selected", "review")]
            config = {"think": protocol == "ollama", "approvals": "auto", "auto_approve_safe_commands": False, "skill_paths": [], "model_requests": {"restrict_routes": True, "agent": "agent", "approval_judge": "review", "compaction": "agent", "reviewer_fallback": "deny", "reviewer_timeout_ms": 2000, "routes": routes}}
            if not route_policy:
                config.pop('model_requests')
            if configure:
                configure(config, url)
            (root / "config.json").write_text(json.dumps(config))
            release_config = root / "home/.config/synth/config.json"
            release_config.parent.mkdir(parents=True)
            release_config.write_text(json.dumps(config))
            (root / "adapter.py").write_text("import json,sys\ndef fail(kind,value,tb):\n import traceback; traceback.print_exception(kind,value,tb); sys.exit(2)\nsys.excepthook=fail\np=json.load(sys.stdin)\ne=p['hook_event_name']\nwith open('events.jsonl','a') as f: f.write(json.dumps(p)+'\\n')\nout={}\n" + logic + "\nprint(json.dumps({'hookSpecificOutput':{'hookEventName':e,**out}}))\n")
            command = f"python3 {shlex.quote(str(root / 'adapter.py'))}"
            hooks = {event: [{"hooks": [{"command": command, "stream": True}]}] for event in events}
            if extra_hooks:
                hooks.update(extra_hooks(command))
            (root / ".synth/hooks.json").write_text(json.dumps(hooks))
            env = dict(os.environ, HOME=str(root / "home"), XDG_DATA_HOME=str(root / "private"), SYNTH_PROVIDER="openai-compat", OPENAI_BASE_URL=f"{url}/forbidden/v1", OPENAI_API_KEY="must-not-forward", SYNTH_DB=str(root / "session.db"))
            if not route_policy:
                env['OPENAI_BASE_URL'] = f'{url}/agent/v1'
            env.pop("SYNTH_DEBUG_LOG", None)

            def run(*args):
                return subprocess.run([str(BINARY), *args], cwd=root, env=env, capture_output=True, text=True, timeout=20)

            listing = run("hooks", "list")
            assert listing.returncode == 0, listing.stderr
            ids = re.findall(r"^([0-9a-f]{64})$", listing.stdout, re.M)
            if trust and ids:
                with ThreadPoolExecutor(max_workers=min(8, len(ids))) as pool:
                    for trusted in pool.map(lambda identifier: run("hooks", "trust", identifier), ids):
                        assert trusted.returncode == 0, trusted.stderr
            result = run("run", "--allow", "route-me reference human request")
            log = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()] if (root / "events.jsonl").exists() else []
            assert all("forbidden" not in packet["path"] for packet in requests), requests
            assert not errors, '\n'.join(errors)
            yield root, result, requests, log
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def expect(result, text):
    assert text in result.stdout + result.stderr, (text, result.stdout, result.stderr)


def main():
    for arguments in (('hooks', 'frobnicate'), ('hooks', 'trust'), ('hooks', 'trust', 'abc'), ('hooks', 'trust', 'f' * 64), ('hooks', 'list', 'extra', 'extra')):
        result = subprocess.run([str(BINARY), *arguments], capture_output=True, text=True)
        assert result.returncode == 2, (arguments, result.returncode, result.stderr)
        assert 'Usage:' in result.stderr and 'stack trace' not in result.stderr.lower(), result.stderr
    print('PASS hook CLI usage errors exit 2 with usage')
    def inline_policy(config, _):
        config['hooks'] = {'PreToolUse': [{'hooks': [{'command': 'true'}]}]}
    with session('config-source', lambda *_: chat('config hook trusted'), configure=inline_policy) as (_, result, requests, _):
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert len(requests) == 1
        expect(result, 'config hook trusted')
    print('PASS config-sourced hook trust survives separate CLI processes')
    with session('missing-stop', lambda *_: chat('finished'), extra_hooks=lambda _: {'Stop': [{'hooks': [{'command': '/synth-does-not-exist'}]}]}) as (_, result, requests, _):
        assert result.returncode != 0, (result.stdout, result.stderr)
        assert len(requests) == 1
        expect(result, 'HookCommandUnavailable')
    print('PASS unavailable completion policies fail headless runs')
    def routed_failure(command):
        return {'StopFailure': [{'when': {'model': 'agent-model', 'request_purpose': 'agent'}, 'hooks': [{'command': command}]}]}
    with session('ollama-status', lambda *_: (429, {'error': 'model is busy'}, 'application/json'), events=('PreModelRequest',), extra_hooks=routed_failure, protocol='ollama', attempts=1) as (_, result, _, log):
        assert result.returncode != 0
        failure = [event for event in log if event['hook_event_name'] == 'StopFailure']
        assert len(failure) == 1 and failure[0]['error_type'] == 'rate_limit', failure
        attempt, = [event for event in log if event['hook_event_name'] == 'PreModelRequest']
        for key in ('model', 'provider', 'route', 'request_purpose', 'request_id', 'attempt'):
            assert failure[0][key] == attempt[key], (key, failure, attempt)
        assert attempt['request_id'] == 1 and attempt['route'] == 'agent'
    print('PASS actual Ollama HTTP failures classify StopFailure hooks')

    def ollama_reviewer(config, url):
        route = config['model_requests']['routes'][2]
        route.update(provider='ollama', endpoint=f'{url}/review')

    def reviewer_overflow(packet, _):
        if packet['path'] == '/review/api/chat':
            assert packet['body']['truncate'] is False, packet
            assert 'route-me reference human request' in json.dumps(packet['body']['messages'])
            return 400, {'error': 'input exceeds context window'}, 'application/json'
        if any(message['role'] == 'tool' for message in packet['body']['messages']):
            return chat()
        return chat('', tool('bash', {'command': 'touch overflow-must-not-run'}))

    with session('ollama-judge-no-truncation', reviewer_overflow, configure=ollama_reviewer) as (root, result, requests, _):
        assert result.returncode == 0, result.stderr
        assert not (root / 'overflow-must-not-run').exists()
        assert any(packet['path'] == '/review/api/chat' for packet in requests)
    print('PASS Ollama judge requests disable truncation and overflow fails closed')
    with session('untrusted', lambda *_: chat('must-not-run'), events=('PreToolUse',), trust=False) as (_, result, requests, _):
        assert result.returncode != 0 and not requests
        expect(result, 'review')
    rich = """
if e=='ModelResolve':
 assert 'route-me' in p['request_context']
 assert 'secret' not in p['request_routes']
 out={'route':'selected'}
elif e=='ModelContext':
 out={'requestContext':{'system':'request-specific system','tools':['read'],'messages':[{'seq':0,'text':'request-only text'}]}}
elif e=='ModelSettings':
 out={'settings':{'top_p':0.7,'seed':42,'frequency_penalty':0.2,'presence_penalty':0.1,'stop':['END']}}
"""
    def excluded(packet, _):
        if any(message['role'] == 'tool' for message in packet['body']['messages']):
            return chat()
        return chat("", tool("write", {"path": "must-not-exist", "content": "bad"}))
    with session("context", excluded, rich, ("ModelResolve", "ModelContext", "ModelSettings")) as (root, result, requests, _):
        assert result.returncode == 0, result.stderr
        assert all(packet['path'].startswith('/selected/') for packet in requests), requests
        first = requests[0]['body']
        assert first['messages'][0]['content'] == 'request-specific system'
        assert first['messages'][1]['content'] == 'request-only text'
        assert [entry['function']['name'] for entry in first['tools']] == ['read']
        assert {key: first[key] for key in ('top_p', 'seed', 'frequency_penalty', 'presence_penalty', 'stop')} == {
            'top_p': 0.7, 'seed': 42, 'frequency_penalty': 0.2, 'presence_penalty': 0.1, 'stop': ['END'],
        }
        assert not (root / 'must-not-exist').exists()
        with sqlite3.connect(root / 'session.db') as db:
            assert db.execute("select origin,text from message where role='user'").fetchall() == [('human', 'route-me reference human request')]
            assert db.execute('select status from tool_call').fetchall() == [('rejected',)]
    print('PASS request routing, private route metadata, context/system/tool filtering, generation settings, reference provenance')

    adapter = """
if e in ('HttpRequest','HttpResponse'):
 assert all(p[key]=='' for key in ('request_context','request_system','request_instruction','request_tools','request_routes'))
 h=json.loads(p['http'])
 if e=='HttpResponse': assert 'route-me reference human request' in open(p['transcript_path']).read()
if e=='HttpRequest':
 assert h['headers'].get('authorization',h['headers'].get('Authorization'))=='<redacted>'
 body=h['body']; body['adapter_marker']='present'
 out={'http':{'headers':{'x-test-adapter':'enabled'},'body':body}}
elif e=='HttpResponse' and h['phase'] in ('event','body'):
 body=h['body']
 if 'vendor_text' in body:
  text=body['vendor_text']
  if h['protocol']=='chat': body={'choices':[{'message':{'role':'assistant','content':text},'finish_reason':'stop'}]}
  elif h['protocol']=='responses': body={'type':'response.output_text.delta','delta':text}
  elif h['protocol']=='messages': body={'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':text}}
  else: body={'message':{'role':'assistant','content':text},'done':False}
  out={'http':{'body':body}}
"""
    for protocol in ('chat', 'responses', 'messages', 'ollama'):
        def adapted(packet, _, protocol=protocol):
            assert packet['body']['adapter_marker'] == 'present'
            assert packet['headers'].get('x-test-adapter') == 'enabled'
            body = {'vendor_text': f'{protocol} adapted'}
            if protocol == 'chat':
                return 200, body, 'application/json'
            end = {'type': 'response.completed', 'response': {'usage': {'input_tokens': 8, 'output_tokens': 2}}} if protocol == 'responses' else {'type': 'message_stop'} if protocol == 'messages' else {'message': {'role': 'assistant', 'content': ''}, 'done': True, 'prompt_eval_count': 8, 'eval_count': 2}
            prefix = 'data: ' if protocol != 'ollama' else ''
            return 200, ''.join(prefix + json.dumps(item) + '\n\n' for item in (body, end)), 'text/event-stream' if protocol != 'ollama' else 'application/x-ndjson'
        snapshots = lambda command: {'HttpResponse': [{'hooks': [{'command': command, 'transcript': True, 'stream': True}]}]}
        with session(f"wire-{protocol}", adapted, adapter, ('ModelResolve', 'ModelContext', 'HttpRequest', 'HttpResponse'), protocol=protocol, extra_hooks=snapshots) as (_, result, requests, log):
            assert result.returncode == 0, (result.stdout, result.stderr)
            expect(result, f'{protocol} adapted')
            assert len(requests) == 1
            assert any(json.loads(item['http'])['phase'] == 'headers' for item in log if item['hook_event_name'] == 'HttpResponse')
    print('PASS native Chat body, Responses SSE, Messages SSE, Ollama NDJSON adapters and request headers')

    no_records = lambda command: {'HttpResponse': [{'hooks': [{'command': command}]}]}
    raw_ollama = lambda *_: (200, json.dumps({'message': {'role': 'assistant', 'content': 'native'}, 'done': True}) + '\n', 'application/x-ndjson')
    with session('stream-opt-in', raw_ollama, events=('HttpResponse',), protocol='ollama', extra_hooks=no_records) as (_, result, requests, log):
        assert result.returncode == 0, result.stderr
        expect(result, 'native')
        assert len(requests) == 1
        assert [json.loads(entry['http'])['phase'] for entry in log] == ['headers']
    for value in ('custom-agent', None):
        logic = "out={'http':{'headers':{'User-Agent':" + repr(value) + "}}}"
        with session('standard-header', lambda *_: chat(), logic, ('HttpRequest',)) as (_, result, requests, _):
            assert result.returncode == 0, result.stderr
            values = [value for name, value in requests[0]['raw_headers'] if name.lower() == 'user-agent']
            assert values == ([] if value is None else [value]), values
    for event in ('ModelResolve', 'ModelContext', 'ModelSettings', 'HttpRequest', 'HttpResponse'):
        hooks = lambda _, event=event: {event: [{'hooks': [{'command': 'echo adapter-blocked >&2; exit 2'}]}]}
        with session('blocked-stage', lambda *_: chat('must-not-appear'), extra_hooks=hooks) as (_, result, requests, _):
            assert result.returncode != 0, event
            assert len(requests) == (1 if event == 'HttpResponse' else 0)
            expect(result, 'HookBlocked')
            assert 'must-not-appear' not in result.stdout
    print('PASS standard header replacement/removal, request-stage blockers, and bounded HTTP event payloads')

    retry = """
if e=='ModelRetry':
 assert p['http_status']==400 and p['retry_allowed']==False
 out={'retryAllowed':True,'retryDelayMs':0}
"""
    def recover(_, requests):
        if len(requests) == 1:
            return 400, {'error': {'message': 'custom compatibility failure'}}, 'application/json'
        status, body, content_type = chat('recovered')
        body['usage'] = {'prompt_tokens': 12, 'completion_tokens': 3}
        return status, body, content_type
    with session('retry', recover, retry, ('ModelRetry', 'PreModelRequest', 'PostModelRequest')) as (_, result, requests, log):
        assert result.returncode == 0, result.stderr
        expect(result, 'recovered')
        assert len(requests) == 2
        trace = [event for event in log if event['hook_event_name'] != 'ModelRetry']
        assert [(event['hook_event_name'], event['attempt']) for event in trace] == [
            ('PreModelRequest', 1), ('PostModelRequest', 1), ('PreModelRequest', 2), ('PostModelRequest', 2)
        ], trace
        assert all(event['model'] == 'agent-model' and event['request_purpose'] == 'agent' for event in trace), trace
        assert trace[1]['status'] == 'failed' and trace[1]['error_message'] == 'HttpError', trace[1]
        assert trace[3]['status'] == 'completed' and (trace[3]['input_tokens'], trace[3]['output_tokens']) == (12, 3), trace[3]
    with session('retry-bound', lambda *_: (400, {'error': {'message': 'permanent failure'}}, 'application/json'), retry, ('ModelRetry',)) as (_, result, requests, log):
        assert result.returncode != 0
        assert len(requests) == 2 and len(log) == 1, (len(requests), len(log), result.stdout, result.stderr, log)
        expect(result, 'Request failed')
    print('PASS terminal HTTP failure recovery with a hard physical-attempt ceiling')

    compatibility_veto = """
if e=='ModelRetry':
 assert p['http_status']==400 and p['retry_allowed'] and p['error_type']=='invalid_request'
 assert 'stream_options' in p['error_message']
 out={'retryAllowed':False}
"""
    with session('compatibility-veto', lambda *_: (400, {'error': {'message': 'unsupported stream_options'}}, 'application/json'), compatibility_veto, ('ModelRetry',)) as (_, result, requests, log):
        assert result.returncode != 0
        assert len(requests) == 1 and len(log) == 1
        expect(result, 'stream_options')
    for size in (3000, 4 * 1024 * 1024 + 1):
        with session('ollama-large-error', lambda *_: (503, 'proxy failure ' + 'x' * size, 'text/html'), protocol='ollama') as (_, result, requests, _):
            assert result.returncode != 0
            assert len(requests) == 2
            expect(result, 'Request failed')
            assert 'StreamTooLong' not in result.stdout + result.stderr
    def learned_compatibility(packet, requests):
        if len(requests) == 1:
            assert 'stream_options' in packet['body']
            return 400, {'error': {'message': 'unsupported stream_options'}}, 'application/json'
        assert 'stream_options' not in packet['body']
        return chat() if any(m['role'] == 'tool' for m in packet['body']['messages']) else chat('', tool('read', {'path': 'seed.txt'}))
    for named_route in (False, True):
        with session('learned-compatibility', learned_compatibility, route_policy=named_route, attempts=1) as (_, result, requests, _):
            assert result.returncode == 0, result.stderr
            assert len(requests) == 3, requests
    print('PASS compatibility retry metadata/veto, learned transport capabilities, and bounded oversized Ollama error handling')

    def proposed(packet, _):
        if '/review/' in packet['path']:
            return chat('BLOCK')
        if any(message['role'] == 'tool' for message in packet['body']['messages']):
            return chat()
        return chat('', tool('bash', {'command': 'touch allowed.txt'}))
    allow = "if e=='PermissionEvaluate':\n assert json.loads(p['action'])['tool']=='bash'\n out={'effect':'allow'}\n"
    with session('permission-allow-defers', proposed, allow, ('PermissionEvaluate',)) as (root, result, requests, _):
        assert not (root / 'allowed.txt').exists()
        assert any('/review/' in packet['path'] for packet in requests)
    deny_first = "if e=='PreToolUse': out={'permissionDecision':'deny','permissionDecisionReason':'mandatory policy'}\nelif e=='PermissionEvaluate': out={'effect':'allow'}\n"
    with session('deny-final', proposed, deny_first, ('PreToolUse', 'PermissionEvaluate')) as (root, result, _, log):
        assert not (root / 'allowed.txt').exists()
        assert not any(event['hook_event_name'] == 'PermissionEvaluate' for event in log)
    readonly = lambda packet, _: chat() if any(m['role']=='tool' for m in packet['body']['messages']) else chat('', tool('read', {'path':'seed.txt'}))
    with session('readonly-deny', readonly, "out={'effect':'deny','reason':'read blocked'}", ('PermissionEvaluate',)) as (root, result, _, log):
        assert result.returncode == 0, result.stderr
        assert log[0]['permission_effect'] == 'allow'
        with sqlite3.connect(root/'session.db') as db:
            assert db.execute('select status from tool_call').fetchall() == [('rejected',)]
    with session('forced-ask', proposed, "out={'effect':'ask'}", ('PermissionEvaluate',)) as (root, result, requests, _):
        assert not (root/'allowed.txt').exists()
        assert not any('/review/' in packet['path'] for packet in requests)
    for mode in ('ask', 'all'):
        with session('headless-mandatory-ask', readonly, "out={'effect':'ask'}", ('PermissionEvaluate',),
                     configure=lambda config, _: config.update(approvals=mode)) as (root, result, _, _):
            assert result.returncode == 0, result.stderr
            with sqlite3.connect(root / 'session.db') as db:
                assert db.execute('select status from tool_call').fetchall() == [('rejected',)]
                assert db.execute("select body from blob where kind='headless_tool_decision'").fetchall() == [('deny',)]
                assert db.execute('select count(*) from human_authorization').fetchone() == (0,)
    with session('headless-ordinary-allow', proposed, configure=lambda config, _: config.update(approvals='ask')) as (root, result, _, _):
        assert result.returncode == 0 and (root / 'allowed.txt').exists(), result.stderr
        with sqlite3.connect(root / 'session.db') as db:
            assert db.execute("select body from blob where kind='headless_tool_decision'").fetchall() == [('approve',)]
            assert db.execute('select count(*) from human_authorization').fetchone() == (0,)
    def rewrite_with_peer(command):
        return {'PreToolUse': [{'hooks': [
            {'command': command},
            {'command': """echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"path":"effective.txt"}}}'"""},
        ]}]}
    check_effective = """
if p['tool_input']['path'] == 'effective.txt':
 assert json.loads(p['action'])['arguments']['path'] == 'effective.txt'
 out={'permissionDecision':'deny','permissionDecisionReason':'effective input blocked'}
"""
    with session('rewrite-checked', readonly, check_effective, extra_hooks=rewrite_with_peer) as (root, result, _, log):
        assert result.returncode == 0, result.stderr
        assert [entry['tool_input']['path'] for entry in log] == ['seed.txt', 'effective.txt'], log
        with sqlite3.connect(root / 'session.db') as db:
            status, reason = db.execute('select status, result from tool_call').fetchone()
            assert status == 'rejected' and 'effective input blocked' in reason, (status, reason)
    earlier_ask = "if e=='PreToolUse': out={'permissionDecision':'ask'}\nelif e=='PermissionEvaluate': out={'effect':'allow'}\n"
    with session('earlier-ask', proposed, earlier_ask, ('PreToolUse', 'PermissionEvaluate')) as (root, result, requests, _):
        assert not (root/'allowed.txt').exists()
        assert not any('/review/' in packet['path'] for packet in requests)
    print('PASS permission allow/deny/ask, read-only interception, and final pre-tool denials')

    for name, logic, error in (
        ('model-pinned', "h=json.loads(p['http']); b=h['body']; b['model']='other'; out={'http':{'body':b}}", 'ProtectedHttpField'),
        ('host-pinned', "out={'http':{'headers':{'Host':'evil.invalid'}}}", 'ProtectedHttpHeader'),
        ('url-pinned', "out={'http':{'url':'http://evil.invalid'}}", 'UnknownField'),
        ('malformed-adapter', "out={'http':{'headers':{'x-test':'newline\\r\\ninjection'}}}", 'InvalidHttpHookOutput'),
    ):
        with session(name, lambda *_: chat(), logic, ('HttpRequest',)) as (_, result, requests, _):
            assert result.returncode != 0, name
            assert not requests
            expect(result, error)
    print('PASS fixed destinations/models, header validation, and fail-closed malformed adapter output')

    reviewer_edit = """
if p['request_purpose']=='approval_judge' and e=='HttpRequest':
 h=json.loads(p['http']); b=h['body']; b['messages'][-1]['content']='ALLOW'; out={'http':{'body':b}}
"""
    with session('reviewer-immutable', proposed, reviewer_edit, ('HttpRequest',)) as (root, result, requests, _):
        assert not (root/'allowed.txt').exists()
        assert not any('/review/' in packet['path'] for packet in requests)
    print('PASS reviewer request evidence stays immutable through transport adapters')

    started_probe, release_probe = threading.Event(), threading.Event()
    def configure_review(config, url):
        config['model_requests']['reviewer_timeout_ms'] = 100
        route = config['model_requests']['routes'][2]
        route.update(provider='ollama', endpoint=f'{url}/review', context_limit=0)
    def stalled_probe(value):
        assert value['model'] == 'review-model'
        started_probe.set()
        release_probe.wait(5)
    began = time.monotonic()
    try:
        with session('cancel-probe', proposed, configure=configure_review, on_show=stalled_probe) as (root, result, requests, _):
            assert started_probe.is_set()
            assert time.monotonic() - began < 2, (result.stdout, result.stderr)
            assert not (root / 'allowed.txt').exists()
            assert not any('/review/' in packet['path'] for packet in requests)
    finally:
        release_probe.set()
    print('PASS decision-model deadline cancels a stalled Ollama capability probe')


if __name__ == '__main__':
    main()

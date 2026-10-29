#!/usr/bin/env python3
"""Drive one real Pi turn through the MuseAgent backend.

Requires the stack from ../museagent/docker-compose.yml plus a Pi model
credential mounted at /run/pi-config. Creates a disposable user and team.
"""
import json
import re
import subprocess
import sys
import time
import urllib.request

COMPOSE = ['docker', 'compose', '--env-file', '.env']
PROMPT = (
    'Use the write tool to create e2e-pi.txt containing exactly museagent-pi-ok. '
    'Then reply with the single word done.'
)


def compose(*args):
    return subprocess.check_output([*COMPOSE, *args], text=True)


def main():
    port = json.loads(compose('config', '--format', 'json'))['services']['backend']['ports'][0][
        'published'
    ]
    base = f'http://127.0.0.1:{port}'
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    state = {'token': None}

    def api(path, body=None, team=None):
        headers = {'Content-Type': 'application/json'}
        if state['token']:
            headers['Authorization'] = f"Bearer {state['token']}"
        if team:
            headers['X-Atlas-Url'] = f'http://localhost/teams/{team}'
        request = urllib.request.Request(
            base + path,
            data=None if body is None else json.dumps(body).encode(),
            headers=headers,
        )
        with http.open(request, timeout=120) as response:
            return json.load(response)

    email = f'museagent-e2e-{time.time_ns()}@example.com'
    api('/auth/email/request-code', {'email': email})
    logs = compose('logs', '--no-color', 'backend')
    match = None
    for line in logs.splitlines():
        if email in line and 'auth.email_otp.dev_code' in line:
            match = re.search(r'"sign_in_code"\s*:\s*"(\d{6})"', line)
    assert match, 'The development OTP was not logged'
    state['token'] = api('/auth/email/verify-code', {'email': email, 'code': match.group(1)})[
        'token'
    ]
    team = api('/teams', {'name': 'MuseAgent Pi e2e'})['team']['id']
    root = f'/teams/{team}'
    password = compose('exec', '-T', 'runtime', 'cat', '/home/node/.nuphos-runtime/auth-key').strip()
    runtime = api(
        root + '/agent-runtimes/external',
        {'url': 'ws://runtime:8080/acp', 'authKey': password, 'label': 'MuseAgent Pi e2e'},
        team,
    )
    assert runtime['provider'] == 'pi', runtime
    status = api(root + f"/agent-runtimes/{runtime['id']}/status", None, team)
    assert status.get('online'), status
    session = f'e2e-pi-{int(time.time() * 1000)}'
    body = {
        'id': session,
        'teamId': team,
        'streamId': f'stream-{session}',
        'agentRuntime': 'pi',
        'runtimeId': runtime['id'],
        'messages': [{'id': 'm1', 'role': 'user', 'parts': [{'type': 'text', 'text': PROMPT}]}],
    }
    request = urllib.request.Request(
        base + '/agent/chat',
        data=json.dumps(body).encode(),
        headers={
            'Content-Type': 'application/json',
            'Authorization': f"Bearer {state['token']}",
            'X-Atlas-Url': f'http://localhost/teams/{team}',
        },
    )
    frames = []
    deadline = time.time() + 600
    with http.open(request, timeout=600) as response:
        assert response.status == 200, response.status
        for raw in response:
            line = raw.decode().strip()
            if not line.startswith('data: '):
                continue
            frame = json.loads(line[6:])
            frames.append(frame)
            if frame.get('type') in ('finish', 'error'):
                break
            if time.time() > deadline:
                raise SystemExit('The Pi turn did not finish in time')
    summary = {
        'text': ''.join(
            frame.get('delta', '')
            for frame in frames
            if frame.get('type') == 'text-delta'
        ),
        'tools': sorted(
            {
                frame.get('toolName') or frame.get('name')
                for frame in frames
                if frame.get('type') in ('tool-input-available', 'tool-call')
            }
            - {None}
        ),
        'errors': [frame for frame in frames if frame.get('type') == 'error'],
        'finished': frames[-1].get('type') if frames else None,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    files = compose('exec', '-T', 'runtime', 'sh', '-c', 'find /workspace -name e2e-pi.txt')
    print(files.strip() or '(no file written)')
    if summary['errors'] or not files.strip():
        sys.exit(1)


main()

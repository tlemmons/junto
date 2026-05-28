#!/usr/bin/env python3
"""
check-auth.py URL API_KEY PROJECT

Validates that an API key can access a given project on a junto-memory server.
Used by junto-setup.sh and junto-check.sh.

Exit codes:
  0  → ok
  1  → invalid_key | permission_denied | unreachable | error
  2  → bad usage

Stdout (one word):
  ok
  invalid_key
  permission_denied
  unreachable
  error
"""
import urllib.request, urllib.error, json, sys


def _parse_sse(body):
    for line in body.split('\n'):
        if line.startswith('data:'):
            try:
                return json.loads(line[5:].strip())
            except Exception:
                pass
    return None


def _inner(outer):
    if not outer:
        return None
    try:
        return json.loads(outer['result']['content'][0]['text'])
    except Exception:
        return None


def _post(url, payload, session_id=None, timeout=10):
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
    }
    if session_id:
        headers['Mcp-Session-Id'] = session_id
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        sid = resp.headers.get('mcp-session-id', '')
        body = resp.read().decode()
        return sid, body
    except urllib.error.HTTPError as e:
        return '', f'http:{e.code}'
    except Exception as e:
        return '', f'err:{e}'


def validate(url, api_key, project):
    """Returns: ok | invalid_key | permission_denied | unreachable | error"""

    # Step 1: MCP initialize handshake
    sid, body = _post(url, {
        'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
        'params': {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'junto-check', 'version': '1.0'}
        }
    })
    if not sid or body.startswith(('err:', 'http:')):
        return 'unreachable'

    # Step 2: memory_start_session — validates the API key
    _, body = _post(url, {
        'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
        'params': {
            'name': 'memory_start_session',
            'arguments': {
                'project': project,
                'claude_instance': 'junto-check',
                'task_description': 'key validation',
                'api_key': api_key
            }
        }
    }, session_id=sid, timeout=15)

    result = _inner(_parse_sse(body))
    if result is None:
        return 'unreachable'

    s = json.dumps(result) if isinstance(result, dict) else str(result)
    if 'Invalid API key' in s or ('invalid' in s.lower() and 'api' in s.lower()):
        return 'invalid_key'

    session_id = result.get('session_id', '') if isinstance(result, dict) else ''
    if not session_id:
        return 'invalid_key'

    # Step 3: test project-scoped access with memory_list_backlog
    _, body = _post(url, {
        'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
        'params': {
            'name': 'memory_list_backlog',
            'arguments': {
                'session_id': session_id,
                'project': project,
                'limit': 1
            }
        }
    }, session_id=sid, timeout=15)

    result = _inner(_parse_sse(body))
    if result is None:
        return 'error'

    s = json.dumps(result) if isinstance(result, dict) else str(result)
    if 'Permission denied' in s or 'Tenant isolation' in s or 'does not have access' in s:
        return 'permission_denied'

    return 'ok'


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print('usage: check-auth.py URL API_KEY PROJECT', file=sys.stderr)
        sys.exit(2)
    outcome = validate(sys.argv[1], sys.argv[2], sys.argv[3])
    print(outcome)
    sys.exit(0 if outcome == 'ok' else 1)

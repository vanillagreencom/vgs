#!/usr/bin/env python3
# Synthetic v0.38.1 CLI replies, source: cli/src/native/actions.rs and
# cli/src/output.rs at vercel-labs/agent-browser v0.38.1, read 2026-10-02.
# Literal action checks follow cli/src/native/policy.rs; CLI mappings follow
# cli/src/commands.rs. A CLI command group is not a policy action.
# Logs argv, explicit environment and policy. Opens no browser or network.
import json, os, pathlib, sys, time
home = pathlib.Path(os.environ.get('HOME', '/nonexistent'))
# Probe has no HOME. The test's stand-in file stores the fixture root beside it.
root = pathlib.Path(__file__).parent.parent
mode_path = root / 'browser-mode.json'
mode = json.loads(mode_path.read_text()) if mode_path.exists() else {}
args = sys.argv[1:]
with (root / 'browser-calls.jsonl').open('a') as log:
    row = {'args': args, 'env': dict(os.environ)}
    if '--action-policy' in args:
        row['policy'] = json.loads(pathlib.Path(args[args.index('--action-policy') + 1]).read_text())
    log.write(json.dumps(row) + '\n')
if args == ['--version']:
    print('agent-browser ' + mode.get('version', '0.38.1'))
    sys.exit(mode.get('versionExit', 0))
if args == ['skills', 'get', 'core']:
    print('fixture installed core guide')
    sys.exit(mode.get('skillExit', 0))
if args == ['install']:
    mode['missing'] = False
    mode_path.write_text(json.dumps(mode))
    sys.exit(mode.get('installExit', 0))
# Remove only fixed global options. This pins the actual CLI call sequence.
command = args[args.index('--json') + 1:]
action = {('open',): 'navigate', ('snapshot',): 'snapshot', ('get', 'url'): 'url',
          ('get', 'attr'): 'getattribute', ('click',): 'click', ('fill',): 'fill',
          ('close',): 'close'}.get(tuple(command[:2] if command[0] == 'get' else command[:1]))
policy = row['policy']
allow = policy.get('allow')
denied = action in policy.get('deny', [])
if allow:
    denied |= action not in allow and policy.get('default', 'deny').lower() == 'deny'
elif allow is None:
    denied |= policy.get('default', '').lower() == 'deny'
if denied:
    print(json.dumps({'success': False, 'error': "Action '{}' denied by policy".format(action)}))
    sys.exit(1)
url_path = home / ('fixture-url-' + os.environ['AGENT_BROWSER_NAMESPACE'])
url = url_path.read_text() if url_path.exists() else 'https://first.test/page'
if mode.get('missing') and command[0] == 'open':
    print(json.dumps({'success': False, 'error': 'Chrome not found. Install Chrome or use --executable-path.'}))
    sys.exit(1)
if mode.get('malformed') and command != ['close']:
    print('not json')
    sys.exit(0)
if mode.get('fail') and command != ['close']:
    print(json.dumps({'success': False, 'error': 'fixture failure'}))
    sys.exit(1)
if command[0] == 'open' and mode.get('delayMs'):
    time.sleep(mode['delayMs'] / 1000)
    (root / 'browser-open-completed').write_text('completed')
if command[0] == 'open':
    url = mode.get('redirect', command[1]); url_path.write_text(url)
    data = {'url': url}
elif command == ['get', 'url']:
    data = {'url': mode.get('verifyUrl', url)}
elif command[0] == 'snapshot':
    data = {'origin': mode.get('site', url), 'snapshot': mode.get('text', 'fixture page @e1 @e2 @e3'),
            'refs': {'e1': {'role': 'textbox', 'name': 'Name'}, 'e2': {'role': 'link', 'name': 'Next'},
                     'e3': {'role': 'button', 'name': 'Send'}}}
elif command[:2] == ['get', 'attr']:
    data = {'origin': mode.get('attributeSite', mode.get('site', url)), 'value': mode.get('type', 'text')}
elif command[0] == 'click':
    data = {'clicked': command[1]}
elif command[0] == 'fill':
    data = {'filled': command[1]}
elif command == ['close']:
    if mode.get('closeFail'):
        print(json.dumps({'success': False, 'error': 'close failed'})); sys.exit(0)
    data = {'closed': True}
else:
    print(json.dumps({'success': False, 'error': 'unexpected argv'})); sys.exit(2)
print(json.dumps({'success': True, 'data': data, '_boundary': {'nonce': 'fixture-nonce', 'origin': url}}))

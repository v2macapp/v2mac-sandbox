"""Real-VM check of store recipes and Debian updates (plan §10): a recipe installs through apt, an upgrade waits for
open apps and then swaps in, and a new base rebuilds the package root. Needs build-rootfs.sh, build-base.sh and
DEV=1 build-helper.sh (the test switches). Runs isolated in a temporary folder, with the host's network as the mini VM's exit; never touches an
installed V2Mac. Downloads about 300 MB from Debian. Usage: python3 Scripts/test-recipes.py
"""
import hashlib, json, os, pathlib, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time

here = pathlib.Path(__file__).resolve().parents[1]
workspace = here.parent
root = pathlib.Path(tempfile.mkdtemp(prefix='v2mac-recipes-', dir='/private/tmp'))
print('Isolated runtime:', root, flush=True)
app = root / 'V2Mac Sandbox.app'
subprocess.run(['cp', '-cR', str(here / 'out/V2Mac Sandbox.app'), str(app)], check=True)
base = json.loads((app / 'Contents/Resources/bases.json').read_text())['allowed'][0]
VM_NAME = 'Recipe Check'
generated = pathlib.Path.home() / 'Applications/V2Mac Sandbox' / f'Recipe Check — {VM_NAME}.app'
shared = pathlib.Path.home() / 'V2Mac Sandbox' / VM_NAME
assert not generated.exists() and not shared.exists(), 'test name already in use'

# The recipe: Firefox from Debian, and one settings file of its own.
plugin = root / 'plugin'
plugin.mkdir()
(plugin / 'marker').write_text('from the recipe layer\n')
(plugin / 'Containerfile').write_text('ARG BASE\nFROM ${BASE}\nCOPY marker /etc/recipe-marker\n')
(plugin / 'plugin.json').write_text(json.dumps({'api': 2, 'id': 'recipe-check', 'name': 'Recipe Check', 'version': '1', 'display': 'pty',
    'packages': ['firefox-esr'], 'launch': {'cmd': ['/bin/bash', '-l']}}))
subprocess.run([str(workspace / 'plugin-template/Scripts/package.sh'), str(plugin), base, 'http://127.0.0.1:8765', 'local', 'local'], check=True, cwd=root)
manifest = json.loads((root / 'dist/plugin.json').read_text())
cache = root / 'cache'
cache.mkdir()
layer = manifest['layers'][0]
shutil.copy(root / 'dist' / layer['url'].rsplit('/', 1)[1], cache / layer['sha256'])
(root / 'index.json').write_text(json.dumps({'version': 1, 'expires': '2099-01-01T00:00:00Z', 'minApi': 1, 'plugins': [manifest],
    'templates': [{'id': 'recipe-check', 'name': VM_NAME, 'plugins': ['recipe-check']}], 'revoked': []}))
sign = root / 'sign.swift'
sign.write_text('''import Foundation
import CryptoKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let signature = try key.signature(for: Data(SHA256.hash(data: Data(contentsOf: url))))
try signature.base64EncodedString().write(to: url.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
key = subprocess.check_output(['swift', str(sign), str(root / 'index.json')], text=True).strip()

def image_variant(name, edit):
    """A copy of the built root with sandbox.sh and sources.list edited, for states a fresh build can't reach."""
    out = root / f'{name}.erofs'
    script = f'''set -e
apt-get update -qq && apt-get install -y -qq erofs-utils >/dev/null
fsck.erofs --extract=/tmp/r --preserve /in/rootfs.erofs
{edit}
mkfs.erofs -zlz4hc /out/{name}.erofs /tmp/r >/dev/null'''
    subprocess.run(['docker', 'run', '--rm', '--privileged', '--platform', 'linux/arm64', '-v', f'{here}/out:/in:ro', '-v', f'{root}:/out', 'debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6', 'sh', '-ec', script], check=True)
    return out

# Always check: a test can't wait a day for the lists or the daily stamp to go stale.
ALWAYS = "sed -i 's/-mmin -1440/-mmin -0/g' /tmp/r/usr/local/lib/v2mac/sandbox.sh"
NO_SECURITY = "echo 'deb http://deb.debian.org/debian trixie main' > /tmp/r/etc/apt/sources.list; rm -f /tmp/r/etc/apt/sources.list.d/*"

class Helper:
    def __init__(self, rootfs, install=False):
        shutil.copy(rootfs, app / 'Contents/Resources/rootfs.erofs')
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(here / 'Resources/V2MacSandbox.entitlements'), '--options', 'runtime', str(app)], check=True)
        self.host, child = socket.socketpair()
        self.lock = threading.Lock()
        self.log_path = root / 'helper.log'
        self.start = self.log_path.stat().st_size if self.log_path.exists() else 0
        self.log = open(self.log_path, 'a')
        env = {**os.environ, 'V2MAC_SANDBOX_STORE': 'http://127.0.0.1:8765/', 'V2MAC_SANDBOX_STORE_KEY': key}
        if install: env['V2MAC_SANDBOX_TEMPLATE'] = 'recipe-check'
        wrapper = 'import os,sys; fd=int(sys.argv[1]); os.dup2(fd,3); os.set_inheritable(3,True); os.execv(sys.argv[2],[sys.argv[2]])'
        self.proc = subprocess.Popen([sys.executable, '-c', wrapper, str(child.fileno()), str(app / 'Contents/MacOS/V2Mac Sandbox')],
                                     pass_fds=(child.fileno(),), env=env, stdout=self.log, stderr=subprocess.STDOUT)
        child.close()
        threading.Thread(target=self.link, daemon=True).start()

    def send(self, message):
        body = json.dumps(message).encode()
        with self.lock: self.host.sendall(struct.pack('>I', len(body)) + body)

    def exact(self, n):
        data = b''
        while len(data) < n:
            chunk = self.host.recv(n - len(data))
            if not chunk: raise EOFError
            data += chunk
        return data

    def link(self):
        try:
            while True:
                message = json.loads(self.exact(struct.unpack('>I', self.exact(4))[0]))
                if 'hello' in message:
                    self.send({'hello': {'version': message['hello'].get('version', 3), 'ramCapMB': 4096, 'core': str(workspace / 'app/Vendor/core/xray')}})
                    self.send({'servers': {'_0': [{'id': 'recipe-check', 'name': 'Host network'}], 'active': 'recipe-check'}})
                elif 'outbound' in message:
                    self.send({'outbound': {'id': message['outbound']['id'], 'json': json.dumps({'protocol': 'freedom', 'settings': {}})}})
                elif 'fetch' in message:
                    request = message['fetch']
                    self.send({'downloaded': {'request': request['request'], 'path': str(root / request['url'].rsplit('/', 1)[1])}})
                elif 'download' in message:
                    request = message['download']
                    self.send({'downloaded': {'request': request['request'], 'path': str(cache / request['sha256'])}})
        except (EOFError, OSError): pass

    def logged(self):
        return self.log_path.read_text(errors='replace')[self.start:]

    def wait_log(self, pattern, minutes=30):
        deadline = time.monotonic() + minutes * 60
        while time.monotonic() < deadline:
            found = re.search(pattern, self.logged())
            if found: return found
            assert self.proc.poll() is None, 'helper exited; see ' + str(self.log_path)
            failed = re.search(r'Debian package update failed.*', self.logged())
            assert not failed, failed.group(0)
            time.sleep(2)
        raise AssertionError(f'no {pattern!r} in the log; see {self.log_path}')

    def stop(self):
        try: self.send({'quit': {}})
        except OSError: pass
        try: self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired: self.proc.terminate(); self.proc.wait(timeout=10)
        self.host.close(); self.log.close()

def session(mini):
    pty = socket.socket(socket.AF_UNIX)
    pty.settimeout(180)
    for _ in range(60):
        try: pty.connect(str(root / 'pty.sock')); break
        except OSError: time.sleep(1)
    pty.sendall(f'{mini} recipe-check\n'.encode())
    return pty

def ask(pty, command, end):
    """Runs a command in the app's shell; its output up to the end marker."""
    line = (command + f'; printf "{end[:3]}%s\\n" "{end[3:]}"\n').encode()
    pty.sendall(b'\0' + struct.pack('>H', len(line)) + line)
    output = b''
    while end.encode() not in output:
        chunk = pty.recv(65536)
        assert chunk, output
        output += chunk
    return output.decode(errors='replace')

def firefox(pty):
    text = ask(pty, 'cat /etc/recipe-marker; dpkg-query -W -f "VER=\\${Version}=\\n" firefox-esr', 'ENDMARK')
    assert 'from the recipe layer' in text, 'the recipe layer is missing: ' + text
    return re.search(r'VER=(\d[^=\s]*)=', text).group(1)  # a digit: the terminal also echoes the command

def wait_mini():
    for _ in range(3600):
        try:
            vms = json.loads((root / 'vms.json').read_text())
            if vms and vms[0]['apps']: return vms[0]['id']
        except (OSError, json.JSONDecodeError): pass
        time.sleep(1)
    raise AssertionError('recipe never installed; see ' + str(root / 'helper.log'))

helper = None
try:
    print('1. Install a recipe on a base whose sources lack trixie-security', flush=True)
    helper = Helper(image_variant('old-sources', NO_SECURITY), install=True)
    mini = wait_mini()
    pty = session(mini)
    before = firefox(pty)
    print('   installed Firefox', before, 'and the recipe layer is on top', flush=True)
    # Review F10: the agent read its limits back, and the app runs under them.
    print('  ', helper.wait_log(r'limits memory \d+ MB[^\n]*').group(0), flush=True)
    group = re.search(r'^0::(\S*)', ask(pty, 'cat /proc/self/cgroup', 'CGEND'), re.M).group(1)
    # A private cgroup namespace shows only "/": the holder's check in the agent then is the only proof.
    assert 'v2mac-vm' in group or group == '/', 'the app runs outside its slice: ' + group
    print('   app cgroup', group if group != '/' else '/ (namespaced: INCONCLUSIVE from inside, the agent checks the holder)', flush=True)
    helper.stop(); pty.close()

    print('2. Same base with security sources: staged while the app is open, swapped in after it closes', flush=True)
    helper = Helper(image_variant('new-sources', ALWAYS))
    pty = session(mini)
    assert firefox(pty) == before
    helper.wait_log(r'Debian packages: waiting')
    assert firefox(pty) == before, 'the open app must keep its version'
    print('   finished upgrade waits for the open app', flush=True)
    pty.close()
    helper.wait_log(r'Debian packages: updated')
    pty = session(mini)
    after = firefox(pty)
    assert after != before, f'Firefox stayed at {after}'
    print('   Firefox', before, '->', after, flush=True)
    helper.stop(); pty.close()

    print('3. A new base rebuilds the package root from what was asked for', flush=True)
    # An extra line changes dpkg's status file, which is how a new base shows.
    helper = Helper(image_variant('new-base', ALWAYS + "; echo >> /tmp/r/var/lib/dpkg/status"))
    pty = session(mini)
    firefox(pty)
    helper.wait_log(r'Debian packages: waiting')
    pty.close()
    helper.wait_log(r'Debian packages: updated')
    pty = session(mini)
    rebuilt = firefox(pty)
    print('   rebuilt, Firefox', rebuilt, flush=True)
    helper.stop(); pty.close()
    print('PASSED', flush=True)
finally:
    if helper:
        try: helper.stop()
        except Exception: pass
    if generated.exists(): shutil.rmtree(generated)
    if shared.exists(): shutil.rmtree(shared)
    (root / 'data.img').unlink(missing_ok=True)
    print('Evidence:', root / 'helper.log', flush=True)

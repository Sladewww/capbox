#!/usr/bin/env python3
"""Host credential store, placeholder injection and proxy header rewrite contracts."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

from test_agent_workflows import Fixture, REPO, ROOTFS
import shutil
import importlib.util

NP_PATH = REPO / 'lib' / 'net-proxy.py'
spec = importlib.util.spec_from_file_location('capbox_net_proxy', NP_PATH)
net_proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(net_proxy)


class SecretStoreTests(Fixture):
    def host_private(self):
        return subprocess.check_output([
            'bash', '-c',
            'export CAPBOX_DIR="$1/.capbox" CAPBOX_WORKSPACE="$1"; '
            'source "$2/lib/common.sh"; _capbox_host_state_dir',
            'x', str(self.ws), str(REPO)
        ], env=self.env, text=True).strip()

    def test_set_ls_rm_permissions_and_no_workspace_leak(self):
        r = subprocess.run(
            self.cli + ['secret', 'set', 'openai', '--value-stdin'],
            input='sk-test-REAL-SECRET\n', text=True, env=self.env,
            capture_output=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual(data['stored'], 'openai')
        private = Path(self.host_private())
        secret = private / 'credentials' / 'secrets' / 'openai.json'
        self.assertTrue(secret.is_file())
        self.assertEqual(oct(secret.stat().st_mode & 0o777), '0o600')
        self.assertEqual(oct((private / 'credentials').stat().st_mode & 0o777), '0o700')
        raw = secret.read_text()
        self.assertIn('sk-test-REAL-SECRET', raw)
        # Never lands under workspace .capbox secrets for this feature.
        self.assertFalse(any(self.ws.joinpath('.capbox').rglob('*REAL-SECRET*')))
        listing = json.loads(self.run_cli('secret', 'ls').stdout)
        self.assertEqual(listing['secrets'][0]['name'], 'openai')
        self.assertNotIn('sk-test-REAL-SECRET', self.run_cli('secret', 'ls').stdout)
        self.run_cli('secret', 'rm', 'openai', check=True)
        self.assertFalse(secret.exists())

    def test_import_and_custom_host(self):
        self.env['OPENAI_API_KEY'] = 'from-env-secret'
        r = self.run_cli('secret', 'import', 'openai', '--force')
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run(
            self.cli + ['secret', 'set', '--custom', '--host', 'api.example.com',
                        '--env', 'MY_TOKEN', '--name', 'mytok', '--value-stdin'],
            input='custom-secret-value', text=True, env=self.env,
            capture_output=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        names = {s['name'] for s in json.loads(self.run_cli('secret', 'ls').stdout)['secrets']}
        self.assertEqual(names, {'openai', 'mytok'})

    def test_prepare_requires_net_allow_subset(self):
        subprocess.run(self.cli + ['secret', 'set', 'openai', '--value-stdin'],
                       input='abc', text=True, env=self.env, capture_output=True, check=True)
        private = self.host_private()
        out = subprocess.check_output([
            'env', f'CAPBOX_CRED_PRIVATE={private}',
            'python3', str(REPO / 'lib/credentials-runtime.py'),
            'prepare', '--allow', 'api.openai.com', '--session', 't1'
        ], text=True)
        data = json.loads(out)
        self.assertTrue(data['active'])
        self.assertTrue(data['placeholders']['OPENAI_API_KEY'].startswith('capbox-sec-'))
        self.assertNotIn('abc', data['placeholders']['OPENAI_API_KEY'])
        # Domain not in allowlist → inactive / skipped
        out2 = subprocess.check_output([
            'env', f'CAPBOX_CRED_PRIVATE={private}',
            'python3', str(REPO / 'lib/credentials-runtime.py'),
            'prepare', '--allow', 'evil.example', '--session', 't2'
        ], text=True)
        self.assertFalse(json.loads(out2)['active'])


    def test_agent_credentials_select_only_explicit_grants(self):
        for service in ('openai', 'anthropic'):
            subprocess.run(self.cli + ['secret', 'set', service, '--value-stdin'],
                           input='fixture-' + service, text=True, env=self.env,
                           capture_output=True, check=True, timeout=20)
        directory = self.base / 'prepared'
        directory.mkdir(mode=0o700)
        result = subprocess.run([
            '/usr/bin/python3', '-I', str(REPO / 'lib/credentials-runtime.py'),
            'prepare', '--allow', 'api.openai.com,api.anthropic.com',
            '--output-dir', str(directory), '--grant', 'service:openai',
        ], env={**self.env, 'CAPBOX_CRED_PRIVATE': self.host_private()},
            text=True, capture_output=True, check=True, timeout=20)
        payload = json.loads(result.stdout)
        self.assertEqual(set(payload['placeholders']), {'OPENAI_API_KEY'})
        self.assertNotIn('fixture-openai', result.stdout)
        inject = json.loads((directory / 'inject.json').read_text())
        self.assertTrue(inject['https_only'])
        self.assertEqual([entry['name'] for entry in inject['entries']], ['openai'])
        token = payload['placeholders']['OPENAI_API_KEY']
        _, violation = net_proxy.rewrite_headers_for_credentials(
            ['GET / HTTP/1.1', 'X-Other: ' + token], 'api.openai.com', inject, {}, False)
        self.assertIsNotNone(violation)


class ProxyRewriteTests(unittest.TestCase):
    def test_parallel_proxy_denials_record_only_target_port_and_reason(self):
        from argparse import Namespace
        from concurrent.futures import ThreadPoolExecutor

        def request(audit, task, host):
            observe = net_proxy.deny_observer(Namespace(audit_path=audit, task_id=task))
            client, server = socket.socketpair()
            with client, server:
                client.sendall((f'GET http://{host}/?token=hidden HTTP/1.1\r\n'
                                'Authorization: Bearer private\r\n\r\n').encode())
                net_proxy.handle_client(server, ['allowed.test'], False, on_deny=observe)
                self.assertIn(b'403 Forbidden', client.recv(4096))

        with tempfile.TemporaryDirectory() as directory:
            audit = Path(directory) / 'audit.jsonl'
            cases = [('a' * 32, 'first.test'), ('b' * 32, 'second.test:81')]
            with ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda pair: request(audit, *pair), cases))
            raw = audit.read_text()
            self.assertNotIn('hidden', raw)
            self.assertNotIn('private', raw)
            details = {event['task_id']: event['detail']
                       for event in map(json.loads, raw.splitlines())}
            self.assertEqual(details, {
                'a' * 32: 'target=first.test port=80 reason=allowlist_denied',
                'b' * 32: 'target=second.test port=81 reason=allowlist_denied',
            })

    def test_http_header_rewrite_and_unauthorized(self):
        token = 'capbox-sec-' + ('11' * 16)
        inject = {'entries': [{
            'name': 'openai', 'domains': ['api.openai.com'],
            'header': 'Authorization', 'format': 'Bearer %s',
            'value': 'REAL-OPENAI', 'placeholders': {'OPENAI_API_KEY': token},
        }]}
        lines = ['GET /v1/models HTTP/1.1', f'Authorization: Bearer {token}',
                 'Host: api.openai.com', '']
        out, viol = net_proxy.rewrite_headers_for_credentials(
            lines, 'api.openai.com', inject, {}, False)
        self.assertIsNone(viol)
        self.assertIn('Authorization: Bearer REAL-OPENAI', out)
        _, viol2 = net_proxy.rewrite_headers_for_credentials(
            lines, 'attacker.test', inject, {}, False)
        self.assertIsNotNone(viol2)


class ProxyHttpIntegrationTests(unittest.TestCase):
    def test_proxy_rewrites_http_to_fake_upstream(self):
        token = 'capbox-sec-' + ('22' * 16)
        received = {}

        def upstream():
            srv = socket.socket()
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(('127.0.0.1', 0))
            port = srv.getsockname()[1]
            received['port'] = port
            srv.listen(1)
            received['ready'].set()
            conn, _ = srv.accept()
            data = b''
            while b'\r\n\r\n' not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            received['req'] = data.decode('iso-8859-1', 'replace')
            conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
            conn.close(); srv.close()

        received['ready'] = threading.Event()
        threading.Thread(target=upstream, daemon=True).start()
        self.assertTrue(received['ready'].wait(2))
        port = received['port']
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = Path(tmp) / 'inject.json'
            inject = {'schema': 'capbox.credentials.v1', 'entries': [{
                'name': 'custom', 'domains': ['127.0.0.1'],
                'header': 'Authorization', 'format': '%s',
                'value': 'UPSTREAM-SECRET',
                'placeholders': {'TOK': token},
            }]}
            inject_path.write_text(json.dumps(inject))
            os.chmod(inject_path, 0o600)
            sock = Path(tmp) / 'p.sock'
            ready = Path(tmp) / 'ready'
            proc = subprocess.Popen([
                'python3', str(NP_PATH), 'proxy',
                '--sock', str(sock), '--allow', f'127.0.0.1:{port}',
                '--inject-map', str(inject_path), '--ready', str(ready), '--log'
            ], stderr=subprocess.PIPE)
            try:
                for _ in range(50):
                    if ready.exists() and sock.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(sock.exists())
                # Talk HTTP absolute-form through unix proxy via a tiny client.
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(str(sock))
                req = (
                    f'GET http://127.0.0.1:{port}/ HTTP/1.1\r\n'
                    f'Host: 127.0.0.1:{port}\r\n'
                    f'Authorization: Bearer {token}\r\n'
                    f'Connection: close\r\n\r\n'
                ).encode()
                client.sendall(req)
                client.recv(4096)
                client.close()
                deadline = time.time() + 2
                while 'req' not in received and time.time() < deadline:
                    time.sleep(0.05)
                self.assertIn('req', received)
                self.assertIn('UPSTREAM-SECRET', received['req'])
                self.assertNotIn(token, received['req'])
            finally:
                proc.terminate(); proc.wait(timeout=5)


@unittest.skipUnless((ROOTFS / 'bin/sh').exists() or (ROOTFS / 'bin/sh').is_symlink(),
                     'real rootfs required')
class GuestPlaceholderTests(Fixture):
    def setUp(self):
        super().setUp()
        shutil.copytree(ROOTFS, self.ws / '.capbox/os/alpine', symlinks=True)

    def test_guest_printenv_has_placeholder_not_secret(self):
        secret = 'SUPER-SECRET-KEY-LEAK-PROBE'
        subprocess.run(self.cli + ['secret', 'set', 'openai', '--value-stdin'],
                       input=secret, text=True, env=self.env,
                       capture_output=True, check=True)
        self.env['CAPBOX_NET_ALLOW'] = 'api.openai.com'
        r = self.run_cli('exec', '--net', 'restricted', '--', 'printenv', 'OPENAI_API_KEY')
        self.assertEqual(r.returncode, 0, r.stderr)
        val = r.stdout.strip()
        self.assertTrue(val.startswith('capbox-sec-'), val)
        self.assertNotIn(secret, r.stdout + r.stderr)
        # Guest environ dump must not contain the raw host secret either.
        r_env = self.run_cli('exec', '--net', 'restricted', '--', 'sh', '-c',
                             'printenv; printf "\n---\n"; wc -c </proc/self/environ')
        self.assertEqual(r_env.returncode, 0, r_env.stderr)
        self.assertNotIn(secret, r_env.stdout + r_env.stderr)
        self.assertIn('OPENAI_API_KEY=capbox-sec-', r_env.stdout)
        # Session guest.env on the host is placeholders only.
        private = Path(subprocess.check_output([
            'bash', '-c',
            'export CAPBOX_DIR="$1/.capbox" CAPBOX_WORKSPACE="$1"; '
            'source "$2/lib/common.sh"; _capbox_host_state_dir',
            'x', str(self.ws), str(REPO)
        ], env=self.env, text=True).strip())
        env_files = list((private / 'credentials' / 'sessions').rglob('guest.env'))
        self.assertTrue(env_files)
        for path in env_files:
            body = path.read_text()
            self.assertNotIn(secret, body)
            self.assertIn('capbox-sec-', body)
        # Restricted allowlist still blocks other hosts (policy/proxy path).
        r2 = self.run_cli('policy', 'check', '--net', 'restricted', 'https://example.com/')
        self.assertEqual(r2.returncode, 1)


def _make_test_ca(cn):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    import datetime as dt

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=1))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(
            digital_signature=True, key_cert_sign=True, crl_sign=True,
            content_commitment=False, key_encipherment=False, data_encipherment=False,
            key_agreement=False, encipher_only=False, decipher_only=False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), critical=False)
        .sign(key, hashes.SHA256())
    )
    return key, cert


def _make_test_leaf(cn, ca_key, ca_cert):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    import datetime as dt
    import ipaddress

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = dt.datetime.now(dt.timezone.utc)
    try:
        san = [x509.IPAddress(ipaddress.ip_address(cn))]
    except ValueError:
        san = [x509.DNSName(cn)]
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=1))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    return key, cert


def _write_key_cert(directory, name, key, cert):
    from cryptography.hazmat.primitives import serialization

    directory = Path(directory)
    key_path = directory / f'{name}.key'
    cert_path = directory / f'{name}.crt'
    key_path.write_bytes(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()))
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    for path in (key_path, cert_path):
        os.chmod(path, 0o600)
    return key_path, cert_path


def _read_one_request(conn):
    data = b''
    while b'\r\n\r\n' not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return data
        data += chunk
    head, sep, rest = data.partition(b'\r\n\r\n')
    length = 0
    for line in head.split(b'\r\n'):
        if line.lower().startswith(b'content-length:'):
            length = int(line.split(b':', 1)[1].strip())
            break
    body = rest
    while len(body) < length:
        chunk = conn.recv(4096)
        if not chunk:
            break
        body += chunk
    return head + sep + body[:length]


def _serve_tls_once(ctx, received):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('127.0.0.1', 0))
        received['port'] = server.getsockname()[1]
        server.listen(1)
        received['ready'].set()
        raw, _ = server.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as exc:
            received['tls_error'] = type(exc).__name__
            raw.close()
            return
        with conn:
            try:
                request = _read_one_request(conn)
            except (ssl.SSLError, OSError):
                request = b''
            if request:
                received['request'] = request
            try:
                conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
            except (ssl.SSLError, OSError):
                pass
    finally:
        server.close()


def _serve_http_once(received):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('127.0.0.1', 0))
        received['port'] = server.getsockname()[1]
        server.listen(1)
        received['ready'].set()
        conn, _ = server.accept()
        with conn:
            try:
                request = _read_one_request(conn)
            except OSError:
                request = b''
            if request:
                received['request'] = request
            try:
                conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
            except OSError:
                pass
    finally:
        server.close()


class HttpsCredentialInjectionTests(unittest.TestCase):
    """End-to-end MITM: verify the upstream certificate, then inject only the configured header.

    The proxy trusts a test upstream CA and mints guest-facing certificates from a
    separate CapBox CA. Each case runs a real proxy process over an AF_UNIX socket and
    records exactly what the test upstream received.
    """

    TOKEN = 'capbox-sec-' + ('33' * 16)
    # Test-only replacement value, generated at runtime so no credential literal lives in
    # the repository. The inject map is written 0600 inside a temporary directory.
    REPLACEMENT = 'E2E-' + uuid.uuid4().hex

    @classmethod
    def setUpClass(cls):
        from cryptography.hazmat.primitives import serialization

        cls._tmp = tempfile.TemporaryDirectory(prefix='cb-mitm-')
        root = Path(cls._tmp.name)

        up_ca_key, up_ca_cert = _make_test_ca('Upstream Test CA')
        cls.up_key, cls.up_cert = _make_test_leaf('127.0.0.1', up_ca_key, up_ca_cert)
        cls.wrong_key, cls.wrong_cert = _make_test_leaf('wrong.example', up_ca_key, up_ca_cert)
        mitm_ca_key, mitm_ca_cert = _make_test_ca('CapBox Test CA')
        _, unrelated_ca_cert = _make_test_ca('Unrelated Test CA')

        cls.up_key_path, cls.up_cert_path = _write_key_cert(root, 'up', cls.up_key, cls.up_cert)
        cls.wrong_key_path, cls.wrong_cert_path = _write_key_cert(root, 'wrong', cls.wrong_key, cls.wrong_cert)
        cls.mitm_key_path, cls.mitm_cert_path = _write_key_cert(root, 'mitm', mitm_ca_key, mitm_ca_cert)

        # The proxy verifies the upstream chain with this file.
        cls.up_ca_path = root / 'up-ca.crt'
        cls.up_ca_path.write_bytes(up_ca_cert.public_bytes(serialization.Encoding.PEM))
        # A different CA the proxy trusts; the test upstream chain must fail against it.
        cls.unrelated_ca_path = root / 'unrelated-ca.crt'
        cls.unrelated_ca_path.write_bytes(unrelated_ca_cert.public_bytes(serialization.Encoding.PEM))
        for path in (cls.up_ca_path, cls.unrelated_ca_path):
            os.chmod(path, 0o600)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _start_upstream(self, cert_path=None, key_path=None):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(str(cert_path or self.up_cert_path), str(key_path or self.up_key_path))
        received = {'ready': threading.Event()}
        thread = threading.Thread(target=_serve_tls_once, args=(ctx, received), daemon=True)
        thread.start()
        self.assertTrue(received['ready'].wait(3), 'TLS upstream did not start')
        return received, thread

    def _start_http_upstream(self):
        received = {'ready': threading.Event()}
        thread = threading.Thread(target=_serve_http_once, args=(received,), daemon=True)
        thread.start()
        self.assertTrue(received['ready'].wait(3), 'HTTP upstream did not start')
        return received, thread

    def _inject_map(self, directory, domains=('127.0.0.1',), https_only=True):
        inject = {
            'schema': 'capbox.credentials.v1',
            'ca_key': str(self.mitm_key_path),
            'ca_cert': str(self.mitm_cert_path),
            'entries': [{
                'name': 'custom', 'domains': list(domains),
                'header': 'Authorization', 'format': '%s',
                'value': self.REPLACEMENT,
                'placeholders': {'TOK': self.TOKEN},
            }],
        }
        if https_only:
            inject['https_only'] = True
        path = Path(directory) / 'inject.json'
        path.write_text(json.dumps(inject))
        os.chmod(path, 0o600)
        return path

    def _start_proxy(self, directory, port, inject_path, ssl_cert_file):
        directory = Path(directory)
        sock_path = directory / 'proxy.sock'
        ready_path = directory / 'ready'
        env = os.environ.copy()
        env['SSL_CERT_FILE'] = str(ssl_cert_file)
        proc = subprocess.Popen([
            'python3', str(NP_PATH), 'proxy',
            '--sock', str(sock_path), '--allow', f'127.0.0.1:{port}',
            '--inject-map', str(inject_path), '--ready', str(ready_path), '--log',
        ], stderr=subprocess.PIPE, env=env)
        deadline = time.time() + 5
        while time.time() < deadline and not (ready_path.exists() and sock_path.exists()):
            if proc.poll() is not None:
                stderr = proc.stderr.read().decode('iso-8859-1', 'replace')
                self.fail(f'proxy exited before ready: {stderr}')
            time.sleep(0.02)
        if not (ready_path.exists() and sock_path.exists()):
            proc.kill()
            self.fail('proxy did not become ready')
        return proc, sock_path

    def _stop_proxy(self, proc):
        proc.terminate()
        try:
            _, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            _, stderr = proc.communicate()
        log = (stderr or b'').decode('iso-8859-1', 'replace')
        self.assertNotIn(self.REPLACEMENT, log, 'proxy log leaked the real credential')
        return log

    def _connect_via_proxy(self, sock_path, port):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(str(sock_path))
        client.sendall(f'CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n'.encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
        return client, response

    def _client_tls(self, client, ca_path):
        ctx = ssl.create_default_context(cafile=str(ca_path))
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return ctx.wrap_socket(client, server_hostname='127.0.0.1')

    def _read_all(self, tls):
        data = b''
        try:
            while True:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
        except (ssl.SSLError, OSError):
            pass
        finally:
            try:
                tls.close()
            except OSError:
                pass
        return data

    _UNAVAILABLE = object()

    def _captured(self, received, thread):
        thread.join(5)
        self.assertFalse(thread.is_alive(), 'upstream thread did not finish')
        return received.get('request', self._UNAVAILABLE)

    def test_verified_upstream_injects_only_configured_header(self):
        received, thread = self._start_upstream()
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp)
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.up_ca_path)
            try:
                client, connect_response = self._connect_via_proxy(sock_path, received['port'])
                self.assertIn(b'200', connect_response.split(b'\r\n', 1)[0])
                tls = self._client_tls(client, self.mitm_cert_path)
                body = f'{{"echo":"{self.TOKEN}"}}'.encode()
                tls.sendall(
                    (f'POST /v1/models?trace={self.TOKEN} HTTP/1.1\r\n'
                     f'Host: 127.0.0.1:{received["port"]}\r\n'
                     f'Authorization: Bearer {self.TOKEN}\r\n'
                     'X-Request-Id: ordinary\r\n'
                     f'Content-Length: {len(body)}\r\n'
                     'Connection: close\r\n\r\n').encode() + body)
                response = self._read_all(tls)
            finally:
                self._stop_proxy(proc)
        request = self._captured(received, thread)
        self.assertIsNot(request, self._UNAVAILABLE, 'verified upstream received no request')
        self.assertIn(b'200', response)
        head, _, sent_body = request.partition(b'\r\n\r\n')
        lines = head.split(b'\r\n')
        self.assertIn(b'Authorization: Bearer ' + self.REPLACEMENT.encode(), lines)
        # Placeholder survives in the request target and body; it never reaches another header.
        self.assertIn(self.TOKEN.encode(), lines[0])
        self.assertNotIn(self.TOKEN.encode(), b'\r\n'.join(lines[1:]))
        self.assertIn(b'X-Request-Id: ordinary', lines)
        self.assertIn(self.TOKEN.encode(), sent_body)
        self.assertNotIn(self.REPLACEMENT.encode(), sent_body)

    def test_cleartext_http_never_injects_locked_credentials(self):
        received, thread = self._start_http_upstream()
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp)
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.up_ca_path)
            try:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(5)
                client.connect(str(sock_path))
                client.sendall(
                    (f'GET http://127.0.0.1:{received["port"]}/ HTTP/1.1\r\n'
                     f'Host: 127.0.0.1:{received["port"]}\r\n'
                     f'Authorization: Bearer {self.TOKEN}\r\n'
                     'Connection: close\r\n\r\n').encode())
                response = b''
                try:
                    while True:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        response += chunk
                except OSError:
                    pass
                client.close()
            finally:
                self._stop_proxy(proc)
        request = self._captured(received, thread)
        self.assertIsNot(request, self._UNAVAILABLE, 'cleartext upstream received no request')
        self.assertIn(b'200', response)
        self.assertIn(self.TOKEN.encode(), request)
        self.assertNotIn(self.REPLACEMENT.encode(), request)

    def test_untrusted_upstream_aborts_before_credential(self):
        received, thread = self._start_upstream()
        log = None
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp)
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.unrelated_ca_path)
            try:
                client, connect_response = self._connect_via_proxy(sock_path, received['port'])
                self.assertIn(b'200', connect_response.split(b'\r\n', 1)[0])
                tls = self._client_tls(client, self.mitm_cert_path)
                response = b''
                try:
                    tls.sendall(
                        (f'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                         f'Authorization: Bearer {self.TOKEN}\r\n'
                         'Connection: close\r\n\r\n').encode())
                    while True:
                        chunk = tls.recv(4096)
                        if not chunk:
                            break
                        response += chunk
                except (ssl.SSLError, OSError):
                    pass
                finally:
                    try:
                        tls.close()
                    except OSError:
                        pass
            finally:
                log = self._stop_proxy(proc)
        thread.join(5)
        self.assertIn('tls_error', received)
        self.assertIn('MITM error', log or '')
        self.assertIn('CERTIFICATE_VERIFY_FAILED', log or '')
        self.assertNotIn('request', received)
        self.assertNotIn(self.REPLACEMENT.encode(), response)

    def test_upstream_hostname_mismatch_aborts_before_credential(self):
        received, thread = self._start_upstream(self.wrong_cert_path, self.wrong_key_path)
        log = None
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp)
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.up_ca_path)
            try:
                client, connect_response = self._connect_via_proxy(sock_path, received['port'])
                self.assertIn(b'200', connect_response.split(b'\r\n', 1)[0])
                tls = self._client_tls(client, self.mitm_cert_path)
                response = b''
                try:
                    tls.sendall(
                        (f'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                         f'Authorization: Bearer {self.TOKEN}\r\n'
                         'Connection: close\r\n\r\n').encode())
                    while True:
                        chunk = tls.recv(4096)
                        if not chunk:
                            break
                        response += chunk
                except (ssl.SSLError, OSError):
                    pass
                finally:
                    try:
                        tls.close()
                    except OSError:
                        pass
            finally:
                log = self._stop_proxy(proc)
        thread.join(5)
        self.assertIn('tls_error', received)
        self.assertIn('MITM error', log or '')
        self.assertIn('CERTIFICATE_VERIFY_FAILED', log or '')
        self.assertNotIn('request', received)
        self.assertNotIn(self.REPLACEMENT.encode(), response)

    def test_placeholder_in_non_configured_header_is_denied_before_upstream(self):
        received, thread = self._start_upstream()
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp)
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.up_ca_path)
            try:
                client, connect_response = self._connect_via_proxy(sock_path, received['port'])
                self.assertIn(b'200', connect_response.split(b'\r\n', 1)[0])
                tls = self._client_tls(client, self.mitm_cert_path)
                tls.sendall(
                    (f'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                     f'X-Trace: {self.TOKEN}\r\n'
                     'Connection: close\r\n\r\n').encode())
                response = self._read_all(tls)
            finally:
                self._stop_proxy(proc)
        request = self._captured(received, thread)
        self.assertIs(request, self._UNAVAILABLE, 'upstream received a denied request')
        self.assertIn(b'403', response)
        self.assertNotIn(self.REPLACEMENT.encode(), response)

    def test_unbound_host_never_receives_real_secret(self):
        received, thread = self._start_upstream()
        with tempfile.TemporaryDirectory() as tmp:
            inject_path = self._inject_map(tmp, domains=('api.example.test',))
            proc, sock_path = self._start_proxy(tmp, received['port'], inject_path, self.up_ca_path)
            try:
                client, connect_response = self._connect_via_proxy(sock_path, received['port'])
                self.assertIn(b'200', connect_response.split(b'\r\n', 1)[0])
                # No MITM for an unbound host: the guest talks TLS to the real upstream.
                tls = self._client_tls(client, self.up_ca_path)
                tls.sendall(
                    (f'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                     f'Authorization: Bearer {self.TOKEN}\r\n'
                     'Connection: close\r\n\r\n').encode())
                response = self._read_all(tls)
            finally:
                self._stop_proxy(proc)
        request = self._captured(received, thread)
        self.assertIsNot(request, self._UNAVAILABLE, 'unbound upstream received no request')
        self.assertIn(b'200', response)
        self.assertIn(b'Authorization: Bearer ' + self.TOKEN.encode(), request)
        self.assertNotIn(self.REPLACEMENT.encode(), request)




class UnboundCredentialHintsTests(Fixture):
    def host_private(self):
        return subprocess.check_output([
            'bash', '-c',
            'export CAPBOX_DIR="$1/.capbox" CAPBOX_WORKSPACE="$1"; '
            'source "$2/lib/common.sh"; _capbox_host_state_dir',
            'x', str(self.ws), str(REPO)
        ], env=self.env, text=True).strip()

    def test_prepare_no_secrets_includes_bind_hint(self):
        private = self.host_private()
        out = subprocess.check_output([
            'env', f'CAPBOX_CRED_PRIVATE={private}',
            'python3', str(REPO / 'lib/credentials-runtime.py'),
            'prepare', '--allow', 'api.openai.com', '--session', 'hint1'
        ], text=True)
        data = json.loads(out)
        self.assertFalse(data['active'])
        self.assertEqual(data['reason'], 'no-secrets')
        self.assertIn('secret set', data['hint'])
        self.assertIn('capbox-sec-', data['hint'])

    def test_prepare_domain_mismatch_includes_net_allow_hint(self):
        subprocess.run(self.cli + ['secret', 'set', 'openai', '--value-stdin'],
                       input='REAL-KEY-SHOULD-NOT-LEAK', text=True, env=self.env,
                       capture_output=True, check=True)
        private = self.host_private()
        out = subprocess.check_output([
            'env', f'CAPBOX_CRED_PRIVATE={private}',
            'python3', str(REPO / 'lib/credentials-runtime.py'),
            'prepare', '--allow', 'evil.example', '--session', 'hint2'
        ], text=True)
        data = json.loads(out)
        self.assertFalse(data['active'])
        self.assertTrue(data['skipped'])
        self.assertIn('NET_ALLOW', data['hint'])
        self.assertNotIn('REAL-KEY-SHOULD-NOT-LEAK', out)


class ProxyUnauthorizedMessageTests(unittest.TestCase):
    def test_unauthorized_host_message_is_actionable(self):
        token = 'capbox-sec-' + ('44' * 16)
        inject = {'entries': [{
            'name': 'openai', 'domains': ['api.openai.com'],
            'header': 'Authorization', 'format': 'Bearer %s',
            'value': 'REAL-OPENAI', 'placeholders': {'OPENAI_API_KEY': token},
        }]}
        lines = ['GET / HTTP/1.1', f'Authorization: Bearer {token}', 'Host: evil.test', '']
        _, viol = net_proxy.rewrite_headers_for_credentials(lines, 'evil.test', inject, {}, False)
        self.assertIsNotNone(viol)
        # Language-agnostic: the message names the host, the binding and the next step.
        self.assertIn('evil.test', viol)
        self.assertIn('openai', viol)
        self.assertIn('NET_ALLOW', viol)
        self.assertNotIn('REAL-OPENAI', viol)


if __name__ == '__main__':
    unittest.main()

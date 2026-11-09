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


class ProxyRewriteTests(unittest.TestCase):
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
        subprocess.run(self.cli + ['secret', 'set', 'openai', '--value-stdin'],
                       input='SUPER-SECRET-KEY', text=True, env=self.env,
                       capture_output=True, check=True)
        self.env['CAPBOX_NET_ALLOW'] = 'api.openai.com'
        r = self.run_cli('exec', '--net', 'restricted', '--', 'printenv', 'OPENAI_API_KEY')
        self.assertEqual(r.returncode, 0, r.stderr)
        val = r.stdout.strip()
        self.assertTrue(val.startswith('capbox-sec-'), val)
        self.assertNotIn('SUPER-SECRET-KEY', r.stdout + r.stderr)
        # Restricted allowlist still blocks other hosts (policy/proxy path).
        r2 = self.run_cli('policy', 'check', '--net', 'restricted', 'https://example.com/')
        self.assertEqual(r2.returncode, 1)


class HttpsMitmTests(unittest.TestCase):
    def test_connect_get_placeholder_becomes_real_header(self):
        # Client trusts CapBox MITM CA; proxy trusts a separate upstream CA.
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        import datetime as dt
        import ipaddress

        token = 'capbox-sec-' + ('33' * 16)
        received = {}

        def make_ca(cn):
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

        def make_leaf(cn, ca_key, ca_cert):
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

        up_ca_key, up_ca_cert = make_ca('Upstream Test CA')
        up_key, up_cert = make_leaf('127.0.0.1', up_ca_key, up_ca_cert)
        mitm_ca_key, mitm_ca_cert = make_ca('CapBox Test CA')

        def upstream():
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            with tempfile.TemporaryDirectory() as tmp:
                k = Path(tmp) / 'k.pem'; c = Path(tmp) / 'c.pem'
                k.write_bytes(up_key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.TraditionalOpenSSL,
                    serialization.NoEncryption()))
                c.write_bytes(up_cert.public_bytes(serialization.Encoding.PEM))
                ctx.load_cert_chain(c, k)
                srv = socket.socket()
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                srv.bind(('127.0.0.1', 0))
                received['port'] = srv.getsockname()[1]
                srv.listen(1)
                received['ready'].set()
                raw, _ = srv.accept()
                conn = ctx.wrap_socket(raw, server_side=True)
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
            tmp = Path(tmp)
            ca_key_path = tmp / 'mitm.key'; ca_cert_path = tmp / 'mitm.crt'
            up_ca_path = tmp / 'up-ca.crt'
            ca_key_path.write_bytes(mitm_ca_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.TraditionalOpenSSL,
                serialization.NoEncryption()))
            ca_cert_path.write_bytes(mitm_ca_cert.public_bytes(serialization.Encoding.PEM))
            up_ca_path.write_bytes(up_ca_cert.public_bytes(serialization.Encoding.PEM))
            for path in (ca_key_path, ca_cert_path, up_ca_path):
                os.chmod(path, 0o600)
            inject = {
                'schema': 'capbox.credentials.v1',
                'ca_key': str(ca_key_path),
                'ca_cert': str(ca_cert_path),
                'entries': [{
                    'name': 'custom', 'domains': ['127.0.0.1'],
                    'header': 'Authorization', 'format': '%s',
                    'value': 'MITM-SECRET',
                    'placeholders': {'TOK': token},
                }],
            }
            inject_path = tmp / 'inject.json'
            inject_path.write_text(json.dumps(inject)); os.chmod(inject_path, 0o600)
            sock = tmp / 'p.sock'; ready = tmp / 'ready'
            env = os.environ.copy()
            env['SSL_CERT_FILE'] = str(up_ca_path)
            proc = subprocess.Popen([
                'python3', str(NP_PATH), 'proxy',
                '--sock', str(sock), '--allow', f'127.0.0.1:{port}',
                '--inject-map', str(inject_path), '--ready', str(ready), '--log'
            ], stderr=subprocess.PIPE, env=env)
            try:
                for _ in range(50):
                    if ready.exists() and sock.exists():
                        break
                    time.sleep(0.05)
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(str(sock))
                client.sendall(f'CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n'.encode())
                resp = b''
                while b'\r\n\r\n' not in resp:
                    resp += client.recv(4096)
                self.assertIn(b'200', resp.split(b'\r\n', 1)[0])
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_REQUIRED
                ctx.load_verify_locations(cafile=str(ca_cert_path))
                tls = ctx.wrap_socket(client, server_hostname='127.0.0.1')
                tls.sendall(
                    f'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n'.encode()
                )
                tls.recv(4096)
                tls.close()
                deadline = time.time() + 3
                while 'req' not in received and time.time() < deadline:
                    time.sleep(0.05)
                self.assertIn('req', received)
                self.assertIn('MITM-SECRET', received['req'])
                self.assertNotIn(token, received['req'])
            finally:
                proc.terminate(); proc.wait(timeout=5)



if __name__ == '__main__':
    unittest.main()

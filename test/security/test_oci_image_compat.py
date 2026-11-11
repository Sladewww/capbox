#!/usr/bin/env python3
"""Docker/OCI 导入兼容性回归：RHEL 只读目录、gzip 层、多平台 attestation、只读树清理。

这些用例在未修复的 image-docker 分支上会失败，可用 pristine 副本对照验证：
  1) /root 0550 同层写 dotfiles -> PermissionError
  2) gzip 层 + SpooledTemporaryFile(mode=w+b) -> EBADF
  3) 多平台 index 的 unknown/unknown attestation -> oci.unsupported_os
  4) image docker rm / --force 删除 0555 目录 -> 「权限不够」并留下 .bak.*
"""
from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def load_oci():
    spec = importlib.util.spec_from_file_location('oci_image_compat', REPO / 'lib' / 'oci-image.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


oci = load_oci()


def _add(tf, name, data=b'', mode=0o644, kind=tarfile.REGTYPE):
    info = tarfile.TarInfo(name)
    info.size = len(data) if kind == tarfile.REGTYPE else 0
    info.mode = mode
    info.type = kind
    tf.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)


def layer_bytes(members) -> bytes:
    """members: ('dir', name, mode) / ('file', name, data, mode)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        for member in members:
            if member[0] == 'dir':
                _add(tf, member[1], mode=member[2], kind=tarfile.DIRTYPE)
            else:
                _add(tf, member[1], data=member[2], mode=member[3])
    return buf.getvalue()


def docker_save(path: Path, layer: bytes) -> None:
    config = json.dumps({
        'architecture': 'amd64',
        'os': 'linux',
        'config': {
            'Env': ['PATH=/usr/bin:/bin'],
            'Entrypoint': ['/bin/sh'],
            'Cmd': ['-c', 'true'],
            'WorkingDir': '/',
            'User': '',
        },
    }).encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        _add(tf, '0/layer.tar', layer)
        _add(tf, '0.json', config)
        _add(tf, 'manifest.json', json.dumps([{
            'Config': '0.json',
            'RepoTags': ['compat:1'],
            'Layers': ['0/layer.tar'],
        }]).encode())
    path.write_bytes(buf.getvalue())


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-compat-extract-')
        self.addCleanup(self.tmp.cleanup)
        self.dest = Path(self.tmp.name) / 'rootfs'
        self.dest.mkdir()

    def test_readonly_dir_accepts_children_and_keeps_mode(self):
        """CentOS 7 的 /root 是 0550：同层要能写 dotfiles，且最终权限不变。"""
        layer = layer_bytes([
            ('dir', 'root', 0o550),
            ('file', 'root/.bash_logout', b'bye\n', 0o644),
            ('file', 'root/.bashrc', b'hi\n', 0o644),
        ])
        writer = oci.RootfsWriter(self.dest)
        try:
            with tarfile.open(fileobj=io.BytesIO(layer), mode='r:') as tf:
                oci.apply_layer_tar(writer, tf)
        finally:
            writer.close()
        self.assertEqual((self.dest / 'root/.bash_logout').read_bytes(), b'bye\n')
        self.assertEqual((self.dest / 'root/.bashrc').read_bytes(), b'hi\n')
        self.assertEqual(stat.S_IMODE((self.dest / 'root').stat().st_mode), 0o550)

    def test_gzip_layer_on_spooled_tempfile(self):
        """SpooledTemporaryFile.mode 是 w+b，GzipFile 不能靠它推断读模式。"""
        layer = layer_bytes([('file', 'etc/motd', b'hello\n', 0o644)])
        blob = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
        self.assertEqual(blob.mode, 'w+b')
        blob.write(gzip.compress(layer))
        blob.seek(0)
        try:
            with oci.open_tar_blob(blob) as tf:
                names = tf.getnames()
        finally:
            blob.close()
        self.assertIn('etc/motd', names)


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-compat-index-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'layout'
        blobs = self.root / 'blobs' / 'sha256'
        blobs.mkdir(parents=True)
        (self.root / 'oci-layout').write_text(
            '{"imageLayoutVersion": "1.0.0"}\n', encoding='utf-8')

        layer = layer_bytes([('file', 'etc/motd', b'linux\n', 0o644)])
        layer_digest = self._write_blob(blobs, layer)
        descs = []
        for os_name, arch in (('linux', 'amd64'), ('unknown', 'unknown')):
            config = json.dumps({
                'architecture': arch,
                'os': os_name,
                'config': {'Env': [], 'Entrypoint': [], 'Cmd': [],
                           'WorkingDir': '/', 'User': ''},
            }).encode()
            config_digest = self._write_blob(blobs, config)
            manifest = json.dumps({
                'schemaVersion': 2,
                'mediaType': 'application/vnd.oci.image.manifest.v1+json',
                'config': {
                    'mediaType': 'application/vnd.oci.image.config.v1+json',
                    'digest': config_digest,
                    'size': len(config),
                },
                'layers': [{
                    'mediaType': 'application/vnd.oci.image.layer.v1.tar',
                    'digest': layer_digest,
                    'size': len(layer),
                }],
            }).encode()
            manifest_digest = self._write_blob(blobs, manifest)
            descs.append({
                'mediaType': 'application/vnd.oci.image.manifest.v1+json',
                'digest': manifest_digest,
                'size': len(manifest),
                'platform': {'os': os_name, 'architecture': arch},
            })
        (self.root / 'index.json').write_text(
            json.dumps({'schemaVersion': 2, 'manifests': descs}), encoding='utf-8')

    @staticmethod
    def _write_blob(blobs: Path, data: bytes) -> str:
        digest = 'sha256:' + hashlib.sha256(data).hexdigest()
        (blobs / digest.split(':', 1)[1]).write_bytes(data)
        return digest

    def test_unknown_platform_attestation_is_skipped(self):
        """Docker Hub 多平台 index 里的 attestation 清单不应阻断导入。"""
        chosen = oci.load_descriptor(self.root, platform=None, index=None, tag=None)
        self.assertEqual(chosen['os'], 'linux')
        self.assertEqual(chosen['architecture'], 'amd64')


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-compat-cli-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.ws = self.base / 'workspace'
        self.ws.mkdir()
        runtime = self.base / 'runtime'
        runtime.mkdir(mode=0o700)
        cap = self.ws / '.capbox'
        for part in ('bin', 'lib', 'skill'):
            shutil.copytree(REPO / part, cap / part)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
        self.env['XDG_RUNTIME_DIR'] = str(runtime)
        self.env['CAPBOX_LANG'] = 'en'
        self.archive = self.base / 'compat.tar'
        docker_save(self.archive, layer_bytes([
            ('dir', 'usr', 0o755),
            ('dir', 'usr/lib64', 0o555),
            ('file', 'usr/lib64/libdemo.so', b'x', 0o444),
        ]))

    def cli(self, *args):
        return subprocess.run(
            [str(REPO / 'bin/capbox'), '--root', str(self.ws), *args],
            env=self.env, capture_output=True, text=True, timeout=60,
        )

    def test_rm_and_force_remove_readonly_trees(self):
        imported = self.cli('image', 'docker', 'import', str(self.archive), '--name', 'ro')
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertEqual(stat.S_IMODE(
            (self.ws / '.capbox/images/docker/ro/rootfs/usr/lib64').stat().st_mode), 0o555)
        removed = self.cli('image', 'docker', 'rm', 'ro')
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse((self.ws / '.capbox/images/docker/ro').exists())

        first = self.cli('image', 'docker', 'import', str(self.archive), '--name', 'force', '--force')
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.cli('image', 'docker', 'import', str(self.archive), '--name', 'force', '--force')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            list((self.ws / '.capbox/images/docker').glob('.bak.*')), [],
            'force 覆盖不应留下 .bak.* 垃圾目录',
        )


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Docker/OCI 镜像展开：不连接 daemon，不在宿主执行镜像命令。"""
from __future__ import annotations

import gzip
import hashlib
import io
import importlib.util
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
    spec = importlib.util.spec_from_file_location('oci_image', REPO / 'lib' / 'oci-image.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


oci = load_oci()


def add_bytes(tf: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(data))


def layer_bytes(members) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        for member in members:
            kind = member[0]
            if kind == 'file':
                _, name, data, mode = member
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = mode
                info.type = tarfile.REGTYPE
                tf.addfile(info, io.BytesIO(data))
            elif kind == 'dir':
                _, name = member
                info = tarfile.TarInfo(name if name.endswith('/') else name + '/')
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tf.addfile(info)
            elif kind == 'symlink':
                _, name, target = member
                info = tarfile.TarInfo(name)
                info.type = tarfile.SYMTYPE
                info.linkname = target
                tf.addfile(info)
            elif kind == 'link':
                _, name, target = member
                info = tarfile.TarInfo(name)
                info.type = tarfile.LNKTYPE
                info.linkname = target
                tf.addfile(info)
            elif kind == 'chr':
                _, name = member
                info = tarfile.TarInfo(name)
                info.type = tarfile.CHRTYPE
                info.devmajor = 1
                info.devminor = 3
                tf.addfile(info)
            else:
                raise AssertionError(kind)
    return buf.getvalue()


def docker_save(path: Path, images: list[dict], gzip_outer: bool = False) -> None:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        manifest = []
        for index, image in enumerate(images):
            layer_names = []
            for number, blob in enumerate(image['layers']):
                lname = f'{index}-{number}/layer.tar'
                add_bytes(tf, lname, blob)
                layer_names.append(lname)
            config = {
                'architecture': image.get('arch', 'amd64'),
                'os': image.get('os', 'linux'),
                'config': {
                    'Env': image.get('env', ['GREETING=from-image']),
                    'Entrypoint': image.get('entrypoint', ['/bin/sh']),
                    'Cmd': image.get('cmd', ['-c', 'true']),
                    'WorkingDir': image.get('workdir', '/'),
                    'User': image.get('user', ''),
                },
            }
            cfg_name = f'{index}.json'
            add_bytes(tf, cfg_name, json.dumps(config).encode())
            manifest.append({
                'Config': cfg_name,
                'RepoTags': image.get('tags', []),
                'Layers': layer_names,
            })
        add_bytes(tf, 'manifest.json', json.dumps(manifest).encode())
    raw = buf.getvalue()
    if gzip_outer:
        raw = gzip.compress(raw)
    path.write_bytes(raw)


def oci_layout(root: Path, layer: bytes, *, arch: str = 'amd64', tag: str = 'demo:1',
               os_name: str = 'linux') -> None:
    config = {
        'architecture': arch,
        'os': os_name,
        'config': {
            'Entrypoint': ['/bin/app'],
            'Cmd': ['--default'],
            'Env': ['FROM=oci'],
            'User': '',
            'WorkingDir': '/',
        },
    }
    config_bytes = json.dumps(config).encode()
    manifest = {
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': {
            'mediaType': 'application/vnd.oci.image.config.v1+json',
            'digest': 'sha256:' + hashlib.sha256(config_bytes).hexdigest(),
            'size': len(config_bytes),
        },
        'layers': [{
            'mediaType': 'application/vnd.oci.image.layer.v1.tar',
            'digest': 'sha256:' + hashlib.sha256(layer).hexdigest(),
            'size': len(layer),
        }],
    }
    manifest_bytes = json.dumps(manifest).encode()
    blobs = root / 'blobs' / 'sha256'
    blobs.mkdir(parents=True)
    (blobs / hashlib.sha256(config_bytes).hexdigest()).write_bytes(config_bytes)
    (blobs / hashlib.sha256(layer).hexdigest()).write_bytes(layer)
    (blobs / hashlib.sha256(manifest_bytes).hexdigest()).write_bytes(manifest_bytes)
    (root / 'oci-layout').write_text('{"imageLayoutVersion": "1.0.0"}\n', encoding='utf-8')
    index = {
        'schemaVersion': 2,
        'manifests': [{
            'mediaType': 'application/vnd.oci.image.manifest.v1+json',
            'digest': 'sha256:' + hashlib.sha256(manifest_bytes).hexdigest(),
            'size': len(manifest_bytes),
            'platform': {'os': os_name, 'architecture': arch},
            'annotations': {'org.opencontainers.image.ref.name': tag},
        }],
    }
    (root / 'index.json').write_text(json.dumps(index), encoding='utf-8')


class MaterializeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-oci-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def extract(self, archive: Path, **kwargs) -> tuple[Path, dict]:
        dest = self.base / f'rootfs-{os.getpid()}-{len(list(self.base.iterdir()))}'
        dest.mkdir()
        meta = oci.materialize(archive, dest, platform=kwargs.get('platform'),
                               index=kwargs.get('index'), tag=kwargs.get('tag'))
        return dest, meta

    def test_whiteout_opaque_symlink_and_hardlink(self):
        layer1 = layer_bytes([
            ('dir', 'usr'),
            ('dir', 'usr/bin'),
            ('file', 'usr/bin/sh', b'#!/bin/sh\n', 0o755),
            ('file', 'usr/bin/busybox', b'bb', 0o755),
            ('symlink', 'bin', 'usr/bin'),
            ('dir', 'data'),
            ('file', 'data/keep', b'yes', 0o644),
            ('file', 'data/drop', b'no', 0o644),
            ('dir', 'dir'),
            ('file', 'dir/a', b'a', 0o644),
            ('file', 'dir/b', b'b', 0o644),
            ('file', 'etc/motd', b'one', 0o644),
            ('symlink', 'etc/abs', '/etc/motd'),
        ])
        layer2 = layer_bytes([
            ('file', 'data/.wh.drop', b'', 0o644),
            ('file', 'dir/.wh..wh..opq', b'', 0o644),
            ('file', 'dir/c', b'c', 0o644),
            ('file', 'etc/motd', b'two', 0o644),
            ('file', 'bin/extra', b'hello', 0o644),
            ('link', 'bin/bb', 'usr/bin/busybox'),
            ('chr', 'dev/null'),
        ])
        archive = self.base / 'demo.tar'
        sentinel = self.base / 'should-not-run'
        docker_save(archive, [{
            'tags': ['demo:1'],
            'layers': [layer1, layer2],
            'cmd': ['-c', f'touch {sentinel}'],
            'entrypoint': ['/bin/sh'],
        }])
        dest, meta = self.extract(archive)
        self.assertFalse(sentinel.exists())
        self.assertEqual((dest / 'etc/motd').read_bytes(), b'two')
        self.assertTrue((dest / 'data/keep').is_file())
        self.assertFalse((dest / 'data/drop').exists())
        self.assertFalse((dest / 'dir/a').exists())
        self.assertEqual((dest / 'dir/c').read_bytes(), b'c')
        self.assertEqual((dest / 'usr/bin/extra').read_bytes(), b'hello')
        self.assertTrue((dest / 'bin').is_symlink())
        self.assertEqual(os.readlink(dest / 'etc/abs'), '/etc/motd')
        self.assertEqual((dest / 'bin/bb').read_bytes(), b'bb')
        self.assertEqual(os.stat(dest / 'bin/bb').st_ino, os.stat(dest / 'usr/bin/busybox').st_ino)
        self.assertFalse((dest / 'dev/null').exists())
        self.assertGreaterEqual(meta['skipped_special'], 1)
        self.assertEqual(meta['format'], 'docker-archive')
        self.assertEqual(meta['repo_tags'], ['demo:1'])
        self.assertEqual(meta['cmd'], ['-c', f'touch {sentinel}'])

    def test_relative_symlink_cannot_escape_onto_host(self):
        marker = Path('/tmp') / f'capbox-oci-escape-{os.getpid()}'
        self.addCleanup(lambda: marker.unlink(missing_ok=True))
        layer = layer_bytes([
            ('symlink', 'jump', '../../../../../../../../tmp/' + marker.name),
            ('file', 'jump/pwned', b'owned', 0o644),
        ])
        archive = self.base / 'bad.tar'
        docker_save(archive, [{'tags': ['bad:1'], 'layers': [layer]}])
        with self.assertRaises(oci.OciError) as caught:
            self.extract(archive)
        self.assertEqual(caught.exception.key, 'oci.unsafe_path')
        self.assertFalse(marker.exists())

    def test_absolute_symlink_stays_inside_rootfs(self):
        marker = Path('/tmp') / f'capbox-oci-abs-{os.getpid()}'
        self.addCleanup(lambda: marker.unlink(missing_ok=True))
        layer = layer_bytes([
            ('symlink', 'jump', '/' + str(marker).lstrip('/')),
            ('file', 'jump', b'nope', 0o644),
        ])
        # 第二成员与符号链接同名，应替换链接而不是写到宿主。
        archive = self.base / 'abs.tar'
        docker_save(archive, [{'tags': ['abs:1'], 'layers': [layer]}])
        dest, _meta = self.extract(archive)
        self.assertFalse(marker.exists())
        self.assertEqual((dest / 'jump').read_bytes(), b'nope')

    def test_rejects_dotdot_member_and_windows(self):
        layer = layer_bytes([('file', '../outside', b'x', 0o644)])
        archive = self.base / 'dot.tar'
        docker_save(archive, [{'tags': ['dot:1'], 'layers': [layer]}])
        with self.assertRaises(oci.OciError) as caught:
            self.extract(archive)
        self.assertEqual(caught.exception.key, 'oci.unsafe_path')
        win = self.base / 'win.tar'
        docker_save(win, [{'tags': ['win:1'], 'os': 'windows', 'layers': [layer_bytes([('file', 'a', b'a', 0o644)])]}])
        with self.assertRaises(oci.OciError) as caught:
            self.extract(win)
        self.assertEqual(caught.exception.key, 'oci.unsupported_os')

    def test_gzip_outer_and_oci_layout_and_platform(self):
        layer = layer_bytes([('file', 'hello', b'gz', 0o644)])
        archive = self.base / 'outer.tar.gz'
        docker_save(archive, [{'tags': ['gz:1'], 'layers': [layer]}], gzip_outer=True)
        dest, meta = self.extract(archive)
        self.assertEqual((dest / 'hello').read_bytes(), b'gz')
        self.assertTrue(meta['source_sha256'].startswith('sha256:'))

        layout = self.base / 'layout'
        oci_layout(layout, layer_bytes([('file', 'from-oci', b'ok', 0o644)]), tag='demo:1')
        dest2 = self.base / 'oci-root'
        dest2.mkdir()
        meta2 = oci.materialize(layout, dest2, platform=None, index=None, tag='demo:1')
        self.assertEqual((dest2 / 'from-oci').read_bytes(), b'ok')
        self.assertEqual(meta2['format'], 'oci-layout')
        self.assertEqual(meta2['entrypoint'], ['/bin/app'])
        self.assertIn('demo:1', meta2['repo_tags'])

        arm = layer_bytes([('file', 'arch', b'arm', 0o644)])
        amd = layer_bytes([('file', 'arch', b'amd', 0o644)])
        multi = self.base / 'multi.tar'
        docker_save(multi, [
            {'tags': ['app:arm'], 'arch': 'arm64', 'layers': [arm]},
            {'tags': ['app:amd'], 'arch': 'amd64', 'layers': [amd]},
        ])
        picked = self.base / 'picked'
        picked.mkdir()
        meta3 = oci.materialize(multi, picked, platform='linux/arm64', index=None, tag=None)
        self.assertEqual((picked / 'arch').read_bytes(), b'arm')
        self.assertEqual(meta3['architecture'], 'arm64')
        with self.assertRaises(oci.OciError) as caught:
            nowhere = self.base / 'no'
            nowhere.mkdir()
            oci.materialize(multi, nowhere, platform='linux/386', index=None, tag=None)
        self.assertEqual(caught.exception.key, 'oci.platform_missing')

    def test_plan_replaces_cmd_and_resolves_user(self):
        root = self.base / 'root'
        (root / 'etc').mkdir(parents=True)
        (root / 'app').mkdir()
        (root / 'etc/passwd').write_text('nobody:x:65534:65534:n:/:/bin/false\n', encoding='utf-8')
        (root / 'etc/group').write_text('nogroup:x:65534:\n', encoding='utf-8')
        meta_path = self.base / 'meta.json'
        meta_path.write_text(json.dumps({
            'entrypoint': ['/bin/app'],
            'cmd': ['--default'],
            'user': 'nobody',
            'workdir': '/missing',
            'env': ['FROM=oci', 'PATH=/usr/bin'],
        }), encoding='utf-8')
        out = self.base / 'plan'
        oci.write_plan(meta_path, root, out, cwd='', user='', entrypoint=None,
                       clear_entrypoint=False, args=['--user-arg'])
        self.assertEqual((out / 'cwd').read_text(encoding='utf-8').strip(), '/')
        self.assertEqual((out / 'uid').read_text(encoding='utf-8').strip(), '65534')
        self.assertEqual((out / 'gid').read_text(encoding='utf-8').strip(), '65534')
        argv = (out / 'argv').read_bytes().split(b'\0')[:-1]
        self.assertEqual(argv, [b'/bin/app', b'--user-arg'])
        oci.write_plan(meta_path, root, out, cwd='/app', user='1:2', entrypoint='/bin/other',
                       clear_entrypoint=False, args=[])
        argv = (out / 'argv').read_bytes().split(b'\0')[:-1]
        self.assertEqual(argv, [b'/bin/other', b'--default'])
        self.assertEqual((out / 'uid').read_text(encoding='utf-8').strip(), '1')
        self.assertEqual((out / 'cwd').read_text(encoding='utf-8').strip(), '/app')

    def test_rejects_bad_env_and_digest(self):
        layer = layer_bytes([('file', 'a', b'a', 0o644)])
        archive = self.base / 'env.tar'
        docker_save(archive, [{
            'tags': ['env:1'],
            'layers': [layer],
            'env': ['NOT AN ENV'],
        }])
        with self.assertRaises(oci.OciError) as caught:
            self.extract(archive)
        self.assertEqual(caught.exception.key, 'oci.env_key')

        layout = self.base / 'bad-digest'
        oci_layout(layout, layer)
        blob = next((layout / 'blobs/sha256').iterdir())
        blob.write_bytes(blob.read_bytes() + b'x')
        dest = self.base / 'bad-root'
        dest.mkdir()
        with self.assertRaises(oci.OciError) as caught:
            oci.materialize(layout, dest, platform=None, index=None, tag=None)
        self.assertEqual(caught.exception.key, 'oci.digest_mismatch')


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='capbox-oci-cli-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.ws = self.base / 'workspace'
        self.ws.mkdir()
        runtime = self.base / 'runtime'
        runtime.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('CAPBOX_')}
        self.env['XDG_RUNTIME_DIR'] = str(runtime)
        self.env['CAPBOX_LANG'] = 'en'
        cap = self.ws / '.capbox'
        shutil.copytree(REPO / 'bin', cap / 'bin')
        shutil.copytree(REPO / 'lib', cap / 'lib')
        shutil.copytree(REPO / 'skill', cap / 'skill')

    def cli(self, *args, check=False):
        return subprocess.run(
            [str(REPO / 'bin/capbox'), '--root', str(self.ws), *args],
            env=self.env, capture_output=True, text=True, timeout=60, check=check,
        )

    def archive(self) -> Path:
        path = self.base / 'app.tar'
        layer = layer_bytes([
            ('file', 'bin/sh', b'#!/bin/sh\n', 0o755),
            ('file', 'etc/motd', b'hello-image\n', 0o644),
        ])
        sentinel = self.base / 'host-sentinel'
        docker_save(path, [{
            'tags': ['app:1'],
            'layers': [layer],
            'entrypoint': ['/bin/sh'],
            'cmd': ['-c', f'touch {sentinel}'],
            'env': ['IMAGE_ENV=inside'],
        }])
        return path

    def test_import_list_show_rm_does_not_execute_or_change_distro(self):
        sentinel = self.base / 'host-sentinel'
        archive = self.archive()
        imported = self.cli('image', 'docker', 'import', str(archive), '--name', 'app')
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertFalse(sentinel.exists())
        self.assertIn('images/docker/app/rootfs', imported.stdout)
        listed = self.cli('image', 'docker', 'list')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn('app', listed.stdout)
        self.assertIn('app:1', listed.stdout)
        shown = self.cli('image', 'docker', 'show', 'app')
        self.assertEqual(shown.returncode, 0, shown.stderr)
        meta = json.loads(shown.stdout)
        self.assertEqual(meta['entrypoint'], ['/bin/sh'])
        self.assertEqual(self.cli('config', 'get', 'DISTRO').stdout.strip(), 'alpine')
        again = self.cli('image', 'docker', 'import', str(archive), '--name', 'app')
        self.assertNotEqual(again.returncode, 0)
        self.assertIn('already exists', again.stderr)
        removed = self.cli('image', 'docker', 'rm', 'app')
        self.assertEqual(removed.returncode, 0, removed.stderr)
        missing = self.cli('image', 'docker', 'show', 'app')
        self.assertNotEqual(missing.returncode, 0)
        self.assertFalse((self.ws / '.capbox/images/docker/app').exists())

    def test_exec_image_and_run_do_not_replace_project_rootfs(self):
        archive = self.archive()
        self.cli('image', 'docker', 'import', str(archive), '--name', 'app', check=True)
        missing = self.cli('exec', '--image', 'nope', '--', 'true')
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('not imported', missing.stderr)
        daemon = self.cli('exec', '--image', 'app', '--daemon', '--', 'true')
        self.assertEqual(daemon.returncode, 2, daemon.stderr)
        self.assertIn('--daemon', daemon.stderr)
        run = self.cli('image', 'docker', 'run', 'app', '--', '-c', 'true')
        # 没有 bwrap 时停在启动器；有 bwrap 时由镜像里的 /bin/sh 执行。
        # 两种情况都不应在宿主创建 sentinel，也不应改 DISTRO。
        self.assertFalse((self.base / 'host-sentinel').exists())
        self.assertEqual(self.cli('config', 'get', 'DISTRO').stdout.strip(), 'alpine')
        if shutil.which('bwrap'):
            self.assertEqual(run.returncode, 0, run.stderr)
        else:
            self.assertNotEqual(run.returncode, 0)
            self.assertTrue(run.stderr)
        mode = (self.ws / '.capbox/images/docker/app/rootfs/bin/sh').stat().st_mode
        self.assertTrue(mode & stat.S_IXUSR)


if __name__ == '__main__':
    unittest.main()

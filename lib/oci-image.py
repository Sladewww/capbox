#!/usr/bin/env python3
"""把 docker save / OCI layout / OCI archive 展开成 rootfs。

不连接 Docker daemon，不执行镜像里的 Entrypoint、Cmd 或 Env。
层文件只按数据写入调用方给出的目录。
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

if sys.version_info < (3, 10):
    print('[capbox] error: oci import requires Python 3.10+', file=sys.stderr)
    sys.exit(5)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18n  # noqa: E402


MAX_LAYER_BYTES = 8 * 1024 ** 3
MAX_ROOTFS_BYTES = 8 * 1024 ** 3
MAX_MEMBERS = 200_000
MAX_ENV_ITEMS = 256
MAX_ENV_VALUE = 32 * 1024
ENV_KEY = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'
GZIP_MAGIC = b'\x1f\x8b'

LAYER_TYPES = {
    'application/vnd.oci.image.layer.v1.tar',
    'application/vnd.oci.image.layer.v1.tar+gzip',
    'application/vnd.oci.image.layer.v1.tar+zstd',
    'application/vnd.docker.image.rootfs.diff.tar',
    'application/vnd.docker.image.rootfs.diff.tar.gzip',
    'application/vnd.docker.image.rootfs.diff.tar.zstd',
}
FOREIGN_HINTS = ('foreign', 'nondistributable')
MANIFEST_TYPES = {
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
}
INDEX_TYPES = {
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
}


class OciError(Exception):
    def __init__(self, code: str, **fields: object) -> None:
        super().__init__(code)
        self.key = code
        self.fields = fields


def host_arch() -> str | None:
    machine = os.uname().machine
    return {
        'x86_64': 'amd64',
        'amd64': 'amd64',
        'aarch64': 'arm64',
        'arm64': 'arm64',
    }.get(machine)


def parse_platform(text: str | None) -> tuple[str, str | None, str | None] | None:
    if not text:
        return None
    parts = text.split('/')
    if len(parts) not in (2, 3) or any(not part or '/' in part for part in parts):
        raise OciError('oci.bad_platform', platform=text)
    os_name, arch = parts[0], parts[1]
    variant = parts[2] if len(parts) == 3 else None
    return os_name, arch, variant


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return 'sha256:' + digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def spool_stream(stream, limit: int) -> tempfile.SpooledTemporaryFile:
    tmp = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
    total = 0
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            tmp.close()
            raise OciError('oci.too_large', limit='8GiB')
        tmp.write(chunk)
    tmp.seek(0)
    return tmp


def zstd_decompress(src) -> tempfile.SpooledTemporaryFile:
    tool = 'zstd'
    try:
        proc = subprocess.run(
            [tool, '-q', '-d', '-c'],
            stdin=src,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as exc:
        raise OciError('oci.zstd_required') from exc
    if proc.returncode != 0:
        raise OciError('oci.zstd_required')
    if len(proc.stdout) > MAX_LAYER_BYTES:
        raise OciError('oci.too_large', limit='8GiB')
    out = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
    out.write(proc.stdout)
    out.seek(0)
    return out


def open_tar_blob(blob) -> tarfile.TarFile:
    """blob 是可 seek 的二进制文件，内容是 tar / tar.gz / tar.zst。"""
    magic = blob.read(4)
    blob.seek(0)
    if magic.startswith(GZIP_MAGIC):
        return tarfile.open(fileobj=gzip.GzipFile(fileobj=blob), mode='r|')
    if magic == ZSTD_MAGIC:
        plain = zstd_decompress(blob)
        return tarfile.open(fileobj=plain, mode='r:')
    return tarfile.open(fileobj=blob, mode='r:')


def open_outer(path: Path):
    """返回 (kind, tar, cleanup_path)。压缩外层先落成可 seek 的 tar。"""
    if path.is_dir():
        if path.is_symlink() or not (path / 'oci-layout').is_file() or not (path / 'index.json').is_file():
            raise OciError('oci.not_an_image', path=str(path))
        return 'oci-layout', None, None
    if path.is_symlink() or not path.is_file():
        raise OciError('oci.not_an_image', path=str(path))
    with path.open('rb') as handle:
        magic = handle.read(6)
    cleanup = None
    tar_path = path
    if magic.startswith(GZIP_MAGIC):
        tmp = tempfile.NamedTemporaryFile(prefix='capbox-oci-', suffix='.tar', delete=False)
        tmp.close()
        cleanup = Path(tmp.name)
        with gzip.open(path, 'rb') as src, cleanup.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        tar_path = cleanup
    elif magic.startswith(ZSTD_MAGIC):
        tmp = tempfile.NamedTemporaryFile(prefix='capbox-oci-', suffix='.tar', delete=False)
        tmp.close()
        cleanup = Path(tmp.name)
        try:
            with cleanup.open('wb') as dst:
                proc = subprocess.run(
                    ['zstd', '-q', '-d', '-c', str(path)],
                    stdout=dst,
                    stderr=subprocess.PIPE,
                    check=False,
                )
        except FileNotFoundError as exc:
            cleanup.unlink(missing_ok=True)
            raise OciError('oci.zstd_required') from exc
        if proc.returncode != 0:
            cleanup.unlink(missing_ok=True)
            raise OciError('oci.zstd_required')
        tar_path = cleanup
    try:
        tf = tarfile.open(tar_path, mode='r:')
    except tarfile.TarError as exc:
        if cleanup is not None:
            cleanup.unlink(missing_ok=True)
        raise OciError('oci.not_an_image', path=str(path)) from exc
    return 'tar', tf, cleanup


class Archive:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.kind, self.tar, self.cleanup = open_outer(path)
        self.format = 'oci-layout' if self.kind == 'oci-layout' else ''

    def close(self) -> None:
        if self.tar is not None:
            self.tar.close()
            self.tar = None
        if self.cleanup is not None:
            self.cleanup.unlink(missing_ok=True)
            self.cleanup = None

    def read_named(self, name: str) -> bytes:
        if self.kind == 'oci-layout':
            file = self.path / name
            if not file.is_file() or file.is_symlink():
                raise OciError('oci.not_an_image', path=name)
            if file.stat().st_size > MAX_LAYER_BYTES:
                raise OciError('oci.too_large', limit='8GiB')
            return file.read_bytes()
        assert self.tar is not None
        try:
            info = self.tar.getmember(name)
        except KeyError as exc:
            raise OciError('oci.not_an_image', path=name) from exc
        if not info.isreg():
            raise OciError('oci.unsafe_path', path=name)
        return _tar_bytes(self.tar, info)

    def blob(self, digest: str) -> bytes:
        if not digest.startswith('sha256:') or len(digest) != 7 + 64:
            raise OciError('oci.digest_mismatch', digest=digest)
        hexpart = digest.split(':', 1)[1]
        if not re.fullmatch(r'[0-9a-f]{64}', hexpart):
            raise OciError('oci.digest_mismatch', digest=digest)
        data = self.read_named(f'blobs/sha256/{hexpart}')
        got = sha256_bytes(data)
        if got != digest:
            raise OciError('oci.digest_mismatch', digest=digest)
        return data


def _members(tf: tarfile.TarFile) -> list[tarfile.TarInfo]:
    found = []
    for info in tf:
        found.append(info)
        if len(found) > MAX_MEMBERS:
            raise OciError('oci.too_large', limit='200000 members')
    return found


def _tar_bytes(tf: tarfile.TarFile, info: tarfile.TarInfo) -> bytes:
    if info.size > MAX_LAYER_BYTES:
        raise OciError('oci.too_large', limit='8GiB')
    handle = tf.extractfile(info)
    if handle is None:
        raise OciError('oci.not_an_image', path=info.name)
    data = handle.read(MAX_LAYER_BYTES + 1)
    if len(data) > MAX_LAYER_BYTES:
        raise OciError('oci.too_large', limit='8GiB')
    return data


def _json_bytes(data: bytes, path: str):
    try:
        value = json.loads(data.decode('utf-8'))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise OciError('oci.not_an_image', path=path) from exc
    if not isinstance(value, (dict, list)):
        raise OciError('oci.not_an_image', path=path)
    return value


def _as_str_list(value, key: str) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        raise OciError('oci.bad_argv', path=key)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise OciError('oci.bad_argv', path=key)
    if any('\0' in item or '\n' in item for item in value):
        raise OciError('oci.bad_argv', path=key)
    return list(value)


def _config_view(config: dict) -> dict:
    inner = config.get('config') or {}
    if not isinstance(inner, dict):
        inner = {}
    env = inner.get('Env') or []
    if not isinstance(env, list) or any(not isinstance(item, str) for item in env):
        raise OciError('oci.env_key', key='Env')
    if len(env) > MAX_ENV_ITEMS:
        raise OciError('oci.too_large', limit=str(MAX_ENV_ITEMS) + ' env')
    clean_env = []
    for item in env:
        if '\0' in item or '\n' in item or '=' not in item:
            raise OciError('oci.env_key', key=item[:64])
        key, value = item.split('=', 1)
        if not ENV_KEY.fullmatch(key) or len(value) > MAX_ENV_VALUE:
            raise OciError('oci.env_key', key=key[:64])
        clean_env.append(f'{key}={value}')
    user = inner.get('User') or ''
    workdir = inner.get('WorkingDir') or ''
    if not isinstance(user, str) or not isinstance(workdir, str):
        raise OciError('oci.bad_argv', path='config')
    if '\0' in user or '\n' in user or '\0' in workdir or '\n' in workdir:
        raise OciError('oci.bad_argv', path='config')
    os_name = config.get('os') or ''
    arch = config.get('architecture') or ''
    if not isinstance(os_name, str) or not isinstance(arch, str):
        raise OciError('oci.not_an_image', path='config')
    if os_name and os_name.lower() != 'linux':
        raise OciError('oci.unsupported_os', os=os_name)
    return {
        'os': os_name.lower() or 'linux',
        'architecture': arch,
        'variant': config.get('variant') or '',
        'entrypoint': _as_str_list(inner.get('Entrypoint'), 'Entrypoint'),
        'cmd': _as_str_list(inner.get('Cmd'), 'Cmd'),
        'env': clean_env,
        'user': user,
        'workdir': workdir if workdir.startswith('/') or workdir == '' else '/' + workdir,
    }


def _platform_of(manifest_desc: dict, config: dict | None) -> tuple[str, str, str]:
    plat = manifest_desc.get('platform') or {}
    if not isinstance(plat, dict):
        plat = {}
    os_name = plat.get('os') or (config or {}).get('os') or ''
    arch = plat.get('architecture') or (config or {}).get('architecture') or ''
    variant = plat.get('variant') or (config or {}).get('variant') or ''
    return str(os_name), str(arch), str(variant)


def _want_platform(explicit: str | None) -> tuple[str, str | None, str | None]:
    parsed = parse_platform(explicit)
    if parsed:
        return parsed
    return 'linux', host_arch(), None


def _matches(os_name: str, arch: str, variant: str, want) -> bool:
    wos, warch, wvar = want
    if warch is None:
        return False
    if os_name and os_name.lower() != wos.lower():
        return False
    if arch and arch != warch:
        return False
    if wvar and variant and variant != wvar:
        return False
    return True


def _layer_digest(item: dict) -> str:
    media = str(item.get('mediaType') or '')
    if any(hint in media for hint in FOREIGN_HINTS):
        raise OciError('oci.foreign_layer', media=media)
    if media and media not in LAYER_TYPES:
        raise OciError('oci.foreign_layer', media=media)
    digest = item.get('digest')
    if not isinstance(digest, str):
        raise OciError('oci.digest_mismatch', digest=str(digest))
    return digest


def load_descriptor(path: Path, *, platform: str | None, index: int | None, tag: str | None) -> dict:
    archive = Archive(path)
    try:
        return _load_descriptor(archive, platform=platform, index=index, tag=tag)
    finally:
        archive.close()


def _docker_manifests(archive: Archive) -> list[dict]:
    raw = archive.read_named('manifest.json')
    data = _json_bytes(raw, 'manifest.json')
    if not isinstance(data, list) or not data:
        raise OciError('oci.not_an_image', path='manifest.json')
    archive.format = 'docker-archive'
    images = []
    for item in data:
        if not isinstance(item, dict):
            raise OciError('oci.not_an_image', path='manifest.json')
        config_name = item.get('Config')
        layers = item.get('Layers')
        if not isinstance(config_name, str) or not isinstance(layers, list):
            raise OciError('oci.not_an_image', path='manifest.json')
        config = _json_bytes(archive.read_named(config_name), config_name)
        if not isinstance(config, dict):
            raise OciError('oci.not_an_image', path=config_name)
        tags = item.get('RepoTags') or []
        if not isinstance(tags, list):
            tags = []
        view = _config_view(config)
        images.append({
            'format': 'docker-archive',
            'repo_tags': [str(t) for t in tags if isinstance(t, str)],
            'layer_names': [str(name) for name in layers],
            'layer_digests': [],
            'config': view,
            'os': view['os'],
            'architecture': view['architecture'],
            'variant': view['variant'],
        })
    return images


def _oci_manifest_from(archive: Archive, desc: dict) -> dict:
    media = str(desc.get('mediaType') or '')
    if media and media not in MANIFEST_TYPES:
        raise OciError('oci.not_an_image', path=media or 'manifest')
    digest = desc.get('digest')
    if not isinstance(digest, str):
        raise OciError('oci.digest_mismatch', digest=str(digest))
    manifest = _json_bytes(archive.blob(digest), digest)
    if not isinstance(manifest, dict):
        raise OciError('oci.not_an_image', path=digest)
    config_desc = manifest.get('config') or {}
    if not isinstance(config_desc, dict):
        raise OciError('oci.not_an_image', path='config')
    config_digest = config_desc.get('digest')
    if not isinstance(config_digest, str):
        raise OciError('oci.digest_mismatch', digest=str(config_digest))
    config = _json_bytes(archive.blob(config_digest), config_digest)
    if not isinstance(config, dict):
        raise OciError('oci.not_an_image', path=config_digest)
    layers = manifest.get('layers') or []
    if not isinstance(layers, list) or not layers:
        raise OciError('oci.no_layers')
    view = _config_view(config)
    os_name, arch, variant = _platform_of(desc, view)
    if view['os']:
        os_name = view['os']
    if view['architecture']:
        arch = view['architecture']
    return {
        'format': archive.format or 'oci-archive',
        'repo_tags': [],
        'layer_names': [],
        'layer_digests': [_layer_digest(item) for item in layers if isinstance(item, dict)],
        'config': view,
        'os': os_name or view['os'],
        'architecture': arch,
        'variant': variant or view['variant'],
        'digest': digest,
    }


def _annotate(image: dict, desc: dict) -> dict:
    ann = desc.get('annotations') or {}
    if isinstance(ann, dict):
        ref = ann.get('org.opencontainers.image.ref.name')
        if isinstance(ref, str) and ref not in image['repo_tags']:
            image['repo_tags'].insert(0, ref)
    return image


def _oci_images(archive: Archive) -> list[dict]:
    index = _json_bytes(archive.read_named('index.json'), 'index.json')
    if not isinstance(index, dict):
        raise OciError('oci.not_an_image', path='index.json')
    manifests = index.get('manifests') or []
    if not isinstance(manifests, list) or not manifests:
        raise OciError('oci.not_an_image', path='index.json')
    archive.format = 'oci-layout' if archive.kind == 'oci-layout' else 'oci-archive'
    images = []
    for desc in manifests:
        if not isinstance(desc, dict):
            raise OciError('oci.not_an_image', path='index.json')
        media = str(desc.get('mediaType') or '')
        if media in INDEX_TYPES:
            nested = _json_bytes(archive.blob(str(desc.get('digest'))), str(desc.get('digest')))
            if not isinstance(nested, dict):
                raise OciError('oci.not_an_image', path='index')
            for child in nested.get('manifests') or []:
                if isinstance(child, dict):
                    images.append(_annotate(_oci_manifest_from(archive, child), child))
            continue
        images.append(_annotate(_oci_manifest_from(archive, desc), desc))
    return images


def _classify(archive: Archive) -> list[dict]:
    if archive.kind == 'oci-layout':
        return _oci_images(archive)
    assert archive.tar is not None
    names = {info.name for info in _members(archive.tar)}
    if 'oci-layout' in names and 'index.json' in names:
        archive.format = 'oci-archive'
        return _oci_images(archive)
    if 'manifest.json' in names:
        return _docker_manifests(archive)
    raise OciError('oci.not_an_image', path=str(archive.path))


def _load_descriptor(archive: Archive, *, platform: str | None, index: int | None, tag: str | None) -> dict:
    images = _classify(archive)
    chosen = _select(images, platform=platform, index=index, tag=tag)
    source = ''
    if archive.path.is_file():
        source = sha256_file(archive.path)
    chosen['source_sha256'] = source
    chosen['source_path'] = str(archive.path)
    return chosen


def _select(images: list[dict], *, platform: str | None, index: int | None, tag: str | None) -> dict:
    if index is not None:
        if index < 0 or index >= len(images):
            raise OciError('oci.bad_index', index=str(index))
        return images[index]
    if tag:
        matched = [img for img in images if tag in img.get('repo_tags', [])]
        if not matched:
            raise OciError('oci.tag_missing', tag=tag)
        images = matched
    if len(images) == 1 and not platform:
        return images[0]
    want = _want_platform(platform)
    matched = [img for img in images if _matches(img.get('os') or '', img.get('architecture') or '', img.get('variant') or '', want)]
    if len(matched) == 1:
        return matched[0]
    if len(images) == 1:
        return images[0]
    available = ', '.join(
        f"{img.get('os') or '?'}/{img.get('architecture') or '?'}{' (' + ','.join(img.get('repo_tags') or []) + ')' if img.get('repo_tags') else ''}"
        for img in images
    ) or '-'
    shown = platform or (want[0] + '/' + (want[1] or '?'))
    raise OciError('oci.platform_missing', platform=shown, available=available)


def normalize_rel(name: str) -> str:
    if not name or '\0' in name or '\\' in name:
        raise OciError('oci.unsafe_path', path=name[:120])
    raw = name
    while raw.startswith('./'):
        raw = raw[2:]
    if raw.startswith('/'):
        raise OciError('oci.unsafe_path', path=name[:120])
    parts = []
    for part in raw.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            raise OciError('oci.unsafe_path', path=name[:120])
        parts.append(part)
    if not parts:
        return ''
    return '/'.join(parts)


def _guest_parts(base_parts: list[str], link: str) -> list[str]:
    if '\0' in link or '\\' in link or '\n' in link:
        raise OciError('oci.unsafe_path', path=link[:120])
    if link.startswith('/'):
        parts: list[str] = []
    else:
        parts = list(base_parts)
    for part in link.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if not parts:
                raise OciError('oci.unsafe_path', path=link[:120])
            parts.pop()
            continue
        parts.append(part)
    return parts


class RootfsWriter:
    def __init__(self, dest: Path) -> None:
        self.dest = dest
        self.bytes = 0
        self.skipped_special = 0
        self.root_fd = os.open(dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def close(self) -> None:
        os.close(self.root_fd)

    def _open_dir(self, parts: list[str], create: bool, depth: int = 0) -> int:
        if depth > 16:
            raise OciError('oci.unsafe_path', path='/'.join(parts)[:120])
        fd = os.dup(self.root_fd)
        walked: list[str] = []
        try:
            for part in parts:
                try:
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    if not create:
                        raise OciError('oci.unsafe_path', path='/'.join(walked + [part]))
                    os.mkdir(part, 0o755, dir_fd=fd)
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except (NotADirectoryError, OSError) as exc:
                    if not create:
                        raise OciError('oci.unsafe_path', path='/'.join(walked + [part])) from exc
                    st = os.lstat(part, dir_fd=fd)
                    if stat.S_ISLNK(st.st_mode):
                        link = os.readlink(part, dir_fd=fd)
                        os.close(fd)
                        fd = -1
                        target = _guest_parts(walked, link)
                        return self._open_dir(target + parts[len(walked) + 1:], create, depth + 1)
                    raise OciError('oci.unsafe_path', path='/'.join(walked + [part])) from exc
                os.close(fd)
                fd = nxt
                walked.append(part)
            return fd
        except Exception:
            if fd >= 0:
                os.close(fd)
            raise

    def _parent(self, rel: str, create: bool) -> tuple[int, str]:
        parts = rel.split('/')
        if len(parts) == 1:
            return os.dup(self.root_fd), parts[0]
        return self._open_dir(parts[:-1], create), parts[-1]

    def _account(self, size: int) -> None:
        self.bytes += size
        if self.bytes > MAX_ROOTFS_BYTES:
            raise OciError('oci.too_large', limit='8GiB')

    def _clear_dir(self, dir_fd: int) -> None:
        for name in os.listdir(f'/proc/self/fd/{dir_fd}'):
            if name in ('.', '..'):
                continue
            self._remove_at(dir_fd, name)

    def _remove_at(self, dir_fd: int, name: str) -> None:
        try:
            st = os.lstat(name, dir_fd=dir_fd)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(st.st_mode) or stat.S_ISREG(st.st_mode) or stat.S_ISFIFO(st.st_mode):
            os.unlink(name, dir_fd=dir_fd)
            return
        if not stat.S_ISDIR(st.st_mode):
            os.unlink(name, dir_fd=dir_fd)
            return
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
        try:
            self._clear_dir(child)
        finally:
            os.close(child)
        os.rmdir(name, dir_fd=dir_fd)

    def _replace_existing(self, parent: int, name: str, want_dir: bool) -> None:
        try:
            st = os.lstat(name, dir_fd=parent)
        except FileNotFoundError:
            return
        is_dir = stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode)
        if want_dir and is_dir:
            return
        self._remove_at(parent, name)

    def apply_whiteout(self, rel: str) -> None:
        parts = rel.split('/')
        base = parts[-1]
        parent_rel = '/'.join(parts[:-1])
        parent, _ = self._parent(rel, create=True)
        try:
            if base == '.wh..wh..opq':
                self._clear_dir(parent)
                return
            if not base.startswith('.wh.'):
                return
            target = base[4:]
            if not target or target in ('.', '..') or '/' in target:
                raise OciError('oci.unsafe_path', path=rel)
            self._remove_at(parent, target)
        finally:
            os.close(parent)
        _ = parent_rel

    def add_member(self, member: tarfile.TarInfo, src) -> None:
        rel = normalize_rel(member.name)
        if not rel:
            return
        base = rel.rsplit('/', 1)[-1]
        if base == '.wh..wh..opq' or base.startswith('.wh.'):
            self.apply_whiteout(rel)
            return
        if member.issym():
            self._add_symlink(rel, member.linkname)
            return
        if member.islnk():
            self._add_hardlink(rel, member.linkname)
            return
        if member.isdir():
            self._add_dir(rel, member.mode)
            return
        if not member.isreg():
            self.skipped_special += 1
            return
        self._add_file(rel, member.mode, src, member.size)

    def _add_dir(self, rel: str, mode: int) -> None:
        parent, name = self._parent(rel, create=True)
        try:
            self._replace_existing(parent, name, want_dir=True)
            try:
                os.lstat(name, dir_fd=parent)
            except FileNotFoundError:
                os.mkdir(name, mode & 0o7777 or 0o755, dir_fd=parent)
        finally:
            os.close(parent)

    def _add_symlink(self, rel: str, link: str) -> None:
        if '\0' in link:
            raise OciError('oci.unsafe_path', path=rel)
        parent, name = self._parent(rel, create=True)
        try:
            self._replace_existing(parent, name, want_dir=False)
            os.symlink(link, name, dir_fd=parent)
        finally:
            os.close(parent)

    def _add_hardlink(self, rel: str, target: str) -> None:
        target_rel = normalize_rel(target)
        if not target_rel:
            raise OciError('oci.unsafe_path', path=target[:120])
        src_parent, src_name = self._parent(target_rel, create=False)
        parent, name = self._parent(rel, create=True)
        try:
            st = os.lstat(src_name, dir_fd=src_parent)
            if not stat.S_ISREG(st.st_mode):
                raise OciError('oci.unsafe_path', path=target[:120])
            self._replace_existing(parent, name, want_dir=False)
            os.link(src_name, name, src_dir_fd=src_parent, dst_dir_fd=parent, follow_symlinks=False)
        finally:
            os.close(src_parent)
            os.close(parent)

    def _add_file(self, rel: str, mode: int, src, size: int) -> None:
        parent, name = self._parent(rel, create=True)
        try:
            self._replace_existing(parent, name, want_dir=False)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            fd = os.open(name, flags, mode & 0o777 or 0o644, dir_fd=parent)
            try:
                left = size
                while left > 0:
                    chunk = src.read(min(1024 * 1024, left))
                    if not chunk:
                        break
                    self._account(len(chunk))
                    os.write(fd, chunk)
                    left -= len(chunk)
            finally:
                os.close(fd)
        finally:
            os.close(parent)


def apply_layer_tar(writer: RootfsWriter, tf: tarfile.TarFile) -> None:
    count = 0
    pending_links: list[tuple[str, str]] = []
    for member in tf:
        count += 1
        if count > MAX_MEMBERS:
            raise OciError('oci.too_large', limit='200000 members')
        if member.islnk():
            rel = normalize_rel(member.name)
            try:
                writer._add_hardlink(rel, member.linkname)
            except (OciError, OSError):
                pending_links.append((rel, member.linkname))
            continue
        src = tf.extractfile(member) if member.isreg() else None
        writer.add_member(member, src)
    for rel, target in pending_links:
        writer._add_hardlink(rel, target)


def apply_layers(archive: Archive, chosen: dict, dest: Path) -> int:
    writer = RootfsWriter(dest)
    skipped = 0
    try:
        if chosen['format'] == 'docker-archive':
            names = chosen['layer_names']
            if not names:
                raise OciError('oci.no_layers')
            for name in names:
                data = archive.read_named(name)
                blob = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
                blob.write(data)
                blob.seek(0)
                with open_tar_blob(blob) as layer:
                    apply_layer_tar(writer, layer)
        else:
            digests = chosen['layer_digests']
            if not digests:
                raise OciError('oci.no_layers')
            for digest in digests:
                data = archive.blob(digest)
                blob = tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)
                blob.write(data)
                blob.seek(0)
                with open_tar_blob(blob) as layer:
                    apply_layer_tar(writer, layer)
        skipped = writer.skipped_special
    finally:
        writer.close()
    return skipped


def materialize(path: Path, dest: Path, *, platform: str | None, index: int | None, tag: str | None) -> dict:
    if dest.is_symlink() or not dest.is_dir():
        raise OciError('oci.unsafe_path', path=str(dest))
    if any(dest.iterdir()):
        raise OciError('oci.unsafe_path', path=str(dest))
    archive = Archive(path)
    try:
        chosen = _load_descriptor(archive, platform=platform, index=index, tag=tag)
        skipped = apply_layers(archive, chosen, dest)
    finally:
        archive.close()
    view = chosen['config']
    return {
        'format': chosen['format'],
        'os': chosen.get('os') or view['os'],
        'architecture': chosen.get('architecture') or view['architecture'],
        'variant': chosen.get('variant') or view['variant'],
        'repo_tags': chosen.get('repo_tags') or [],
        'digest': chosen.get('digest') or '',
        'source_sha256': chosen.get('source_sha256') or '',
        'entrypoint': view['entrypoint'],
        'cmd': view['cmd'],
        'env': view['env'],
        'user': view['user'],
        'workdir': view['workdir'],
        'layers': chosen.get('layer_digests') or chosen.get('layer_names') or [],
        'skipped_special': skipped,
        'ownership': 'importing-user',
    }


def inspect_image(path: Path, *, platform: str | None, index: int | None, tag: str | None) -> dict:
    chosen = load_descriptor(path, platform=platform, index=index, tag=tag)
    view = chosen['config']
    return {
        'format': chosen['format'],
        'os': chosen.get('os') or view['os'],
        'architecture': chosen.get('architecture') or view['architecture'],
        'variant': chosen.get('variant') or view['variant'],
        'repo_tags': chosen.get('repo_tags') or [],
        'digest': chosen.get('digest') or '',
        'source_sha256': chosen.get('source_sha256') or '',
        'entrypoint': view['entrypoint'],
        'cmd': view['cmd'],
        'env': view['env'],
        'user': view['user'],
        'workdir': view['workdir'],
        'layers': chosen.get('layer_digests') or chosen.get('layer_names') or [],
    }


def _read_text_inside(root: Path, rel: str) -> str | None:
    parts = [part for part in rel.split('/') if part]
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            try:
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError:
                return None
            os.close(fd)
            fd = nxt
        try:
            st = os.lstat(parts[-1], dir_fd=fd)
        except OSError:
            return None
        if not stat.S_ISREG(st.st_mode) or st.st_size > 1_000_000:
            return None
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            return os.read(file_fd, st.st_size).decode('utf-8', 'replace')
        finally:
            os.close(file_fd)
    finally:
        os.close(fd)


def _lookup_user(root: Path, spec: str) -> tuple[str, str]:
    if spec == '':
        return '0', '0'
    if re.fullmatch(r'[0-9]+', spec):
        return spec, spec
    if re.fullmatch(r'[0-9]+:[0-9]+', spec):
        uid, gid = spec.split(':', 1)
        return uid, gid
    name, group = spec, ''
    if ':' in spec:
        name, group = spec.split(':', 1)
    passwd = _read_text_inside(root, 'etc/passwd') or ''
    uid = gid = ''
    for line in passwd.splitlines():
        fields = line.split(':')
        if len(fields) >= 4 and fields[0] == name:
            uid, gid = fields[2], fields[3]
            break
    if not uid.isdigit() or not gid.isdigit():
        raise OciError('oci.user_unresolved', user=spec)
    if group:
        if group.isdigit():
            gid = group
        else:
            group_text = _read_text_inside(root, 'etc/group') or ''
            found = ''
            for line in group_text.splitlines():
                fields = line.split(':')
                if len(fields) >= 3 and fields[0] == group and fields[2].isdigit():
                    found = fields[2]
                    break
            if not found:
                raise OciError('oci.user_unresolved', user=spec)
            gid = found
    return uid, gid


def _is_dir_inside(root: Path, guest: str) -> bool:
    """只认真实目录。路径上出现符号链接就当作不存在，调用方改回 /。"""
    rel = guest.lstrip('/')
    if rel == '':
        return True
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in rel.split('/'):
            if part in ('', '.', '..'):
                return False
            try:
                st = os.lstat(part, dir_fd=fd)
            except OSError:
                return False
            if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
                return False
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return True
    finally:
        if fd >= 0:
            os.close(fd)


def write_plan(meta_path: Path, rootfs: Path, out_dir: Path, *, cwd: str, user: str,
               entrypoint: str | None, clear_entrypoint: bool, args: list[str]) -> None:
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    if not isinstance(meta, dict):
        raise OciError('oci.not_an_image', path=str(meta_path))
    ep = [] if clear_entrypoint else list(meta.get('entrypoint') or [])
    if entrypoint is not None:
        if '\0' in entrypoint:
            raise OciError('oci.bad_argv', path='entrypoint')
        ep = [entrypoint]
    cmd = list(args) if args else list(meta.get('cmd') or [])
    argv = ep + cmd
    if not argv or any(not isinstance(item, str) or '\0' in item for item in argv):
        raise OciError('oci.no_argv')
    spec = user if user != '' else str(meta.get('user') or '')
    uid, gid = _lookup_user(rootfs, spec)
    want = cwd or str(meta.get('workdir') or '/') or '/'
    if not want.startswith('/'):
        want = '/' + want
    if not _is_dir_inside(rootfs, want):
        want = '/'
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / 'cwd').write_text(want + '\n', encoding='utf-8')
    (out_dir / 'uid').write_text(uid + '\n', encoding='utf-8')
    (out_dir / 'gid').write_text(gid + '\n', encoding='utf-8')
    blob = b''.join(item.encode('utf-8') + b'\0' for item in argv)
    (out_dir / 'argv').write_bytes(blob)
    env_path = out_dir / 'env'
    pairs = b''
    for item in meta.get('env') or []:
        if not isinstance(item, str) or '=' not in item:
            raise OciError('oci.env_key', key='env')
        key, value = item.split('=', 1)
        if not ENV_KEY.fullmatch(key):
            raise OciError('oci.env_key', key=key)
        pairs += key.encode('utf-8') + b'\0' + value.encode('utf-8') + b'\0'
    env_path.write_bytes(pairs)


def emit_error(lang: str, err: OciError) -> None:
    try:
        catalog = i18n.load_catalog(lang if lang in ('en', 'zh') else 'en')
    except Exception:
        catalog = {}
    prefix = i18n.get(catalog, 'log.prefix.err') if catalog else '[capbox] error:'
    text = i18n.get(catalog, err.key) if catalog else err.key
    for key, value in err.fields.items():
        text = text.replace('{' + key + '}', str(value))
    print(f'{prefix} {text}', file=sys.stderr)


def _lang(value: str | None) -> str:
    if value in ('zh', 'en'):
        return value
    return 'en'


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog='oci-image')
    parser.add_argument('--lang', default=os.environ.get('CAPBOX_UI_LANG', 'en'))
    sub = parser.add_subparsers(dest='cmd', required=True)

    def add_sel(p):
        p.add_argument('--input', required=True)
        p.add_argument('--platform', default='')
        p.add_argument('--index', default='')
        p.add_argument('--tag', default='')

    inspect_p = sub.add_parser('inspect')
    add_sel(inspect_p)
    mat = sub.add_parser('materialize')
    add_sel(mat)
    mat.add_argument('--dest', required=True)
    plan = sub.add_parser('plan')
    plan.add_argument('--meta', required=True)
    plan.add_argument('--rootfs', required=True)
    plan.add_argument('--out-dir', required=True)
    plan.add_argument('--cwd', default='')
    plan.add_argument('--user', default='')
    plan.add_argument('--entrypoint', default=None)
    plan.add_argument('--clear-entrypoint', action='store_true')
    plan.add_argument('args', nargs='*')
    envp = sub.add_parser('env-pairs')
    envp.add_argument('--meta', required=True)

    ns = parser.parse_args(argv)
    lang = _lang(ns.lang)
    index = None
    if getattr(ns, 'index', ''):
        if not str(ns.index).isdigit():
            emit_error(lang, OciError('oci.bad_index', index=str(ns.index)))
            return 2
        index = int(ns.index)
    try:
        if ns.cmd == 'inspect':
            meta = inspect_image(Path(ns.input), platform=ns.platform or None, index=index, tag=ns.tag or None)
            json.dump(meta, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write('\n')
            return 0
        if ns.cmd == 'materialize':
            meta = materialize(Path(ns.input), Path(ns.dest), platform=ns.platform or None, index=index, tag=ns.tag or None)
            json.dump(meta, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write('\n')
            return 0
        if ns.cmd == 'plan':
            entry = ns.entrypoint
            write_plan(Path(ns.meta), Path(ns.rootfs), Path(ns.out_dir), cwd=ns.cwd, user=ns.user,
                       entrypoint=entry, clear_entrypoint=ns.clear_entrypoint, args=ns.args)
            return 0
        if ns.cmd == 'env-pairs':
            meta = json.loads(Path(ns.meta).read_text(encoding='utf-8'))
            out = sys.stdout.buffer
            for item in meta.get('env') or []:
                key, value = item.split('=', 1)
                if not ENV_KEY.fullmatch(key):
                    raise OciError('oci.env_key', key=key)
                out.write(key.encode('utf-8') + b'\0' + value.encode('utf-8') + b'\0')
            return 0
    except OciError as err:
        emit_error(lang, err)
        return 1
    return 2


if __name__ == '__main__':
    sys.exit(main())

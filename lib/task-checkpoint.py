"""Archive an ended isolated task and restore it into a new local project."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

SCHEMA = 'capbox.task-checkpoint.v1'
FILES = ('workspace.tar.gz', 'rootfs.tar.gz', 'recipe.env')


def separate_path(path, workspace, failure):
    path = Path(path).absolute()
    if '..' in path.parts or path.resolve().is_relative_to(workspace):
        raise failure('Checkpoint paths must be outside the current project.')
    return path


def check_workspace_archive(archive, agent, envkit):
    seen, total, files = set(), 0, 0
    with tarfile.open(archive, 'r:gz') as incoming:
        for member in incoming:
            parts = agent.safe_relative(member.name).parts
            if parts[0] != 'workspace' or member.name in seen:
                raise envkit.Failure('Invalid checkpoint workspace path.')
            seen.add(member.name)
            rel = '/'.join(parts[1:])
            if ((rel and agent.excluded(rel)) or
                    not (member.isdir() or (rel and member.isreg()))):
                raise envkit.Failure('Unsupported entry in checkpoint workspace.')
            total += member.size
            files += member.isreg()
            if total > agent.MAX_COPY or files > agent.MAX_FILES or len(seen) > 100000:
                raise envkit.Failure('Checkpoint workspace exceeds its archive limits.')
    if 'workspace' not in seen:
        raise envkit.Failure('Checkpoint workspace directory is missing.')


def capture(agent, envkit, ctx, job, output):
    state = agent.state_of(job)
    if not state['isolated'] or state['status'] not in agent.FINISHED:
        raise envkit.Failure('Checkpoint requires a finished isolated task.')
    plan = agent.read_json(job / 'plan.json')
    view = job / 'workspace'
    if plan['workspace'] != str(view) or ctx['workspace'] != plan['origin']:
        raise envkit.Failure('Task workspace does not match its recorded project.')
    envkit.real_directory(view)
    output = separate_path(output, ctx['workspace'], envkit.Failure)
    separate_path(output, job, envkit.Failure)
    parent = envkit.real_directory(output.parent)
    keys = state['policy']['values']
    config = {**plan['config'], **{k: v['value'] for k, v in keys.items()}}
    config = envkit.portable_config(dict(config=config, sources=plan['sources']))
    # The launch policy records profile-derived values and CLI overrides.
    config['ROOTFS_RO'] = keys['ROOTFS_RO']['value']
    if plan['config'].get('DISK_MAX') or config.get('FS_BINDS'):
        raise envkit.Failure('Checkpoint requires a task without extra filesystem binds or a disk quota mount.')
    distro = config['DISTRO']
    rootfs = envkit.real_directory(view / '.capbox/os' / distro)

    # Follow the task diff file scope and reject unsupported links before archiving.
    files = agent.regular_files(view)
    with tempfile.TemporaryDirectory(prefix='.capbox-checkpoint-', dir=parent) as temp:
        stage = Path(temp)
        archive = stage / 'workspace.tar.gz'
        with tarfile.open(archive, 'x:gz') as workspace:
            directory = tarfile.TarInfo('workspace')
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            workspace.addfile(directory)
            for name, recorded in sorted(files.items()):
                data, info = agent.read_regular(view, name)
                if (hashlib.sha256(data).hexdigest() != recorded['sha256'] or
                        bool(info.st_mode & 0o111) != recorded['executable']):
                    raise envkit.Failure('Task workspace changed during checkpoint.')
                member = tarfile.TarInfo('workspace/' + name)
                member.mode = 0o755 if recorded['executable'] else 0o644
                member.size = len(data)
                member.mtime = int(info.st_mtime)
                workspace.addfile(member, io.BytesIO(data))
        upper = view / '.capbox/run/overlay/active/upper'
        if any(path.is_symlink() for path in (upper, *upper.parents[:3])):
            raise envkit.Failure('Checkpoint overlay path must not contain symlinks.')
        if upper.exists() and not upper.is_dir():
            raise envkit.Failure('Checkpoint overlay upper must be a directory.')
        if upper.is_dir() and any(upper.iterdir()):
            envkit.real_directory(upper)
            rootfs = Path(shutil.copytree(rootfs, stage / distro, symlinks=True))
            agent.merge_overlay_upper(upper, rootfs)
        envkit.validate_launch_directories(rootfs)
        subprocess.run(['tar', '--numeric-owner', '-czf', str(stage / FILES[1]),
                        '-C', str(rootfs.parent), distro], check=True, timeout=300)
        if rootfs.parent == stage:
            shutil.rmtree(rootfs)
        check_workspace_archive(archive, agent, envkit)
        envkit.preflight_tar(stage / FILES[1], distro)
        recipe = stage / FILES[2]
        recipe.write_text(envkit.recipe_text(config))
        envkit.success(envkit.cli(ctx, 'recipe', 'check', recipe), 'Invalid checkpoint recipe')
        manifest = {'schema': SCHEMA, 'architecture': platform.machine(),
                    'distro': distro, 'config': config, 'task_id': job.name,
                    'files': {name: envkit.digest(stage / name) for name in FILES}}
        (stage / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
        envkit.publish_directory(stage, output)
    return {'kind': 'checkpoint_created', 'path': str(output), 'task_id': job.name,
            'manifest_sha256': envkit.digest(output / 'manifest.json')}


def extract_image(envkit, ctx, archive, destination):
    script = 'source "$1/common.sh"; source "$1/image.sh"; _image_extract_archive "$2" "$3"'
    proc = subprocess.run(['bash', '-c', script, 'checkpoint', ctx['lib'], archive, destination],
                          capture_output=True, timeout=300)
    envkit.success(proc, 'Checkpoint extraction failed')


def restore(agent, envkit, ctx, source, destination, expected):
    source = envkit.real_directory(separate_path(source, ctx['workspace'], envkit.Failure))
    destination = separate_path(destination, ctx['workspace'], envkit.Failure)
    separate_path(destination, source, envkit.Failure)
    if destination == Path.home().resolve() or destination.name == '.capbox':
        raise envkit.Failure('Invalid checkpoint restore project path.')
    if destination.exists() or destination.is_symlink():
        raise envkit.Failure('Checkpoint restore requires a target that does not exist.')
    parent = envkit.real_directory(destination.parent)
    with tempfile.TemporaryDirectory(prefix='.capbox-restore-', dir=parent) as temp:
        stage = Path(temp)
        for name in (*FILES, 'manifest.json'):
            envkit.copy_artifact(source / name, stage / name)
        manifest_path = stage / 'manifest.json'
        if expected is not None and envkit.digest(manifest_path) != expected:
            raise envkit.Failure('Checkpoint manifest SHA256 does not match.')
        manifest = json.loads(envkit.read_file(manifest_path, 1024**2), object_pairs_hook=envkit.unique)
        if (not isinstance(manifest, dict) or
                set(manifest) != {'schema', 'architecture', 'distro', 'task_id', 'files', 'config'} or
                manifest['schema'] != SCHEMA or manifest['architecture'] != platform.machine() or
                manifest['distro'] not in ('alpine', 'ubuntu') or
                not isinstance(manifest['task_id'], str) or
                not re.fullmatch('[0-9a-f]{32}', manifest['task_id']) or
                not isinstance(manifest['files'], dict) or
                set(manifest['files']) != set(FILES)):
            raise envkit.Failure('Invalid checkpoint manifest.')
        config = manifest['config']
        if (not isinstance(config, dict) or not all(isinstance(v, str) for v in config.values()) or
                set(config) - envkit.PORTABLE or config.get('DISTRO') != manifest['distro'] or
                config.get('FS_BINDS')):
            raise envkit.Failure('Invalid checkpoint configuration.')
        for name in FILES:
            if envkit.digest(stage / name) != manifest['files'][name]:
                raise envkit.Failure(f'Checkpoint SHA256 does not match: {name}')
        recipe = stage / FILES[2]
        if envkit.read_file(recipe, 1024**2).decode() != envkit.recipe_text(config):
            raise envkit.Failure('Checkpoint recipe does not match its manifest.')
        check_workspace_archive(stage / FILES[0], agent, envkit)
        envkit.preflight_tar(stage / FILES[1], manifest['distro'])
        with tarfile.open(stage / FILES[0], 'r:gz') as archive:
            archive.extractall(stage, filter='data')
        workspace = envkit.real_directory(stage / 'workspace')
        restored = dict(ctx, workspace=str(workspace))
        # Apply only the verified pure-data recipe in the staged project.
        env = {k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'XDG_RUNTIME_DIR') if k in os.environ}
        envkit.success(envkit.cli(restored, 'bootstrap', env=env), 'Checkpoint bootstrap failed')
        envkit.success(envkit.cli(restored, 'recipe', 'apply', recipe, env=env),
                       'Checkpoint recipe could not be applied')
        os_dir = workspace / '.capbox/os'
        extract_image(envkit, ctx, stage / FILES[1], os_dir)
        rootfs = envkit.real_directory(os_dir / manifest['distro'])
        envkit.validate_launch_directories(rootfs)
        ready = subprocess.run(['bash', '-c', 'source "$1/common.sh"; rootfs_ready_at "$2"',
                                'checkpoint', ctx['lib'], rootfs], capture_output=True, timeout=10)
        envkit.success(ready, 'Checkpoint rootfs is missing its shell')
        # Change project visibility once, after all extraction and validation succeed.
        envkit.publish_directory(workspace, destination)
    return {'kind': 'checkpoint_restored', 'workspace': str(destination), 'task_id': manifest['task_id']}

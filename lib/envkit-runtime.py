#!/usr/bin/env python3
"""宿主就绪计划与内容锁定的离线环境快照。"""
import argparse
import ctypes
import ctypes.util
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

if sys.version_info < (3, 10):
    print('[capbox] 此功能需要宿主 Python 3.10+', file=sys.stderr)
    sys.exit(5)

SCHEMA = 'capbox.envkit.v1'

def mcp_defaults():
    spec=importlib.util.spec_from_file_location('capbox_mcp_defaults', Path(__file__).with_name('mcp-defaults.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def build_mcp_parser(parent=None):
    defaults=mcp_defaults()
    mcp=argparse.ArgumentParser(prog='capbox mcp', parents=[] if parent is None else [parent], add_help=True)
    # main() 与测试共用；选项与默认值集中在此。
    mcp.add_argument('action', choices=['serve'])
    mcp.add_argument('--profile', choices=list(defaults.ALLOWED_PROFILES),
                     default=defaults.DEFAULT_PROFILE,
                     help='安全配置档（默认: %(default)s)')
    mcp.add_argument('--net', choices=list(defaults.ALLOWED_NET),
                     default=defaults.DEFAULT_NET,
                     help='网络模式（默认: %(default)s；拒绝 open）')
    mcp.add_argument('--workspace-mode', choices=list(defaults.ALLOWED_WORKSPACE_MODES),
                     default=defaults.DEFAULT_WORKSPACE_MODE,
                     help='任务工作区（默认: %(default)s)')
    mcp.add_argument('--max-timeout', type=int, default=defaults.DEFAULT_MAX_TIMEOUT,
                     help='任务超时上限秒数（默认: %(default)s)')
    return mcp

BUNDLE_SCHEMA = 'capbox.bundle.v1'
FILES = ('rootfs.tar.gz', 'package.lock', 'recipe.env')
MAX_ARCHIVE = 4 * 1024**3
MAX_EXPANDED = 8 * 1024**3
PORTABLE = {'DISTRO', 'MIRROR', 'NET', 'NET_ALLOW', 'HOSTNAME', 'EXEC_TIMEOUT',
            'MEMORY_MAX', 'CPU_MAX', 'PIDS_MAX', 'RESOURCES_MODE', 'IDMAP',
            'EXEC_UID', 'EXEC_GID', 'SECURITY_PROFILE', 'LANDLOCK', 'ROOTFS_RO',
            'FS_HIDE', 'FS_BINDS', 'OVERLAY', 'AUDIT', 'AUDIT_CMD'}


class Failure(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def context():
    env = os.environ
    keys = env['CAPBOX_ENVKIT_KEYS'].split()
    return {'workspace': str(Path(env['CAPBOX_ENVKIT_WORKSPACE']).resolve()),
            'rootfs': env['CAPBOX_ENVKIT_ROOTFS'], 'state': env['CAPBOX_ENVKIT_DIR'],
            'cli': env['CAPBOX_ENVKIT_CLI'], 'lib': env['CAPBOX_ENVKIT_LIB'],
            'version': env['CAPBOX_ENVKIT_VERSION'],
            'config': {k:env['CAPBOX_ENVKIT_CFG_'+k] for k in keys},
            'sources': {k:env['CAPBOX_ENVKIT_SOURCE_'+k] for k in keys}}


def environment(ctx):
    env = {k:os.environ[k] for k in ('PATH','HOME','LANG','TERM','XDG_RUNTIME_DIR','XDG_STATE_HOME') if k in os.environ}
    for k,v in ctx['config'].items():
        if k == 'ALLOW_OLD_BWRAP' or (k == 'ROOTFS_RO' and ctx['sources'][k] == 'default'):
            continue
        env['CAPBOX_'+k] = v
    if 'CAPBOX_CGROUP_ROOT' in os.environ:
        env['CAPBOX_CGROUP_ROOT'] = os.environ['CAPBOX_CGROUP_ROOT']
    return env


def cli(ctx, *args, env=None, timeout=60):
    proc = subprocess.run([ctx['cli'],'--root',ctx['workspace'],*map(str,args)],
                          env=environment(ctx) if env is None else env, capture_output=True,
                          timeout=timeout)
    return proc


def success(proc, message):
    if proc.returncode:
        raise Failure(message + '（退出码 %d）' % proc.returncode)
    return proc.stdout


def json_output(data, human=False):
    if not human:
        print(json.dumps(dict(schema=SCHEMA, **data), ensure_ascii=True))
    else:
        for key, value in data.items():
            print('%s: %s' % (key,json.dumps(value,ensure_ascii=False)))


def os_release():
    data = {}
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            k, sep, v = line.partition('=')
            if sep and k in ('ID','ID_LIKE','VERSION_ID'):
                fields = shlex.split(v)
                data[k] = fields[0] if fields else ''
    except (OSError, ValueError):
        pass
    return data


def installed_version(ctx):
    for name in ('version.sh','common.sh'):
        file=Path(ctx['state'])/'lib'/name
        if not file.exists():continue
        try:
            real_directory(file.parent)
            text=read_file(file,256*1024).decode()
            match=re.search(r'^readonly CAPBOX_VERSION="([0-9A-Za-z.+-]+)"$',text,re.M)
            if match:return match[1]
        except (OSError,ValueError,Failure):return 'unreadable'
    return None


def readiness(ctx, probe):
    cfg = ctx['config']; items = []
    required = ['bash','python3','bwrap','tar','curl','flock']
    optional = ['timeout','gcc','newuidmap','newgidmap','nsenter','git']
    if cfg['NET'] == 'restricted':
        required.append('nsenter')
    if cfg['IDMAP'] == 'on':
        required += ['newuidmap','newgidmap']
    landlock = cfg['LANDLOCK'] == 'on' or (not cfg['LANDLOCK'] and cfg['SECURITY_PROFILE']=='strict')
    if landlock:
        required.append('gcc')
    for name in sorted(set(required+optional)):
        path = cfg['BWRAP'] if name=='bwrap' else shutil.which(name)
        status = 'available' if path and os.access(path,os.X_OK) else 'missing'
        detail = ''
        if status=='available' and name in ('bash','python3','bwrap'):
            try:
                p = subprocess.run([path,'--version'],capture_output=True,text=True,timeout=5)
                detail = (p.stdout or p.stderr).splitlines()[0][:180]
                match = re.search(r'(\d+)\.(\d+)(?:\.(\d+))?',detail)
                minimum = {'bash':(4,4,0),'python3':(3,10,0),'bwrap':(0,12,0)}[name]
                if p.returncode or not match or tuple(int(n or 0) for n in match.groups()) < minimum:
                    status='unsupported'
            except (OSError,subprocess.SubprocessError,IndexError):
                status='unknown'
        items.append({'id':name,'required':name in required,'status':status,'path':path,'detail':detail})
    try:
        ctypes.CDLL(ctypes.util.find_library('seccomp') or 'libseccomp.so.2')
        seccomp='available'
    except OSError:
        seccomp='missing'
    items.append({'id':'libseccomp','required':cfg['DISTRO']=='alpine' or cfg['SECURITY_PROFILE']!='compat',
                  'status':seccomp})
    items.append({'id':'python-safe-extract','required':True,
                  'status':'available' if hasattr(tarfile,'data_filter') and hasattr(os.path,'ALLOW_MISSING') else 'unsupported',
                  'detail':'环境包恢复需要带安全补丁的 tarfile data filter 与 realpath ALLOW_MISSING'})
    if probe and shutil.which('gcc'):
        with tempfile.TemporaryDirectory(prefix='capbox-setup-') as temporary:
            p=subprocess.run(['gcc','-static','-x','c','-o',str(Path(temporary)/'probe'),'-'],
                             input=b'int main(void){return 0;}\n',capture_output=True,timeout=30)
            items.append({'id':'gcc-static','required':landlock,
                          'status':'available' if p.returncode==0 else 'unavailable'})
    else:
        items.append({'id':'gcc-static','required':landlock,'status':'not_probed',
                      'detail':'setup check --probe 会探测宿主静态工具链'})
    supported = platform.system()=='Linux' and platform.machine() in ('x86_64','aarch64')
    ready = supported and all(i['status']=='available' for i in items if i['required'])
    sysctls={}
    for name in ('unprivileged_userns_clone','apparmor_restrict_unprivileged_userns'):
        path=Path('/proc/sys/kernel')/name
        if path.is_file():
            sysctls[name]=path.read_text().strip()
    return {'kind':'host_readiness','dependencies_ready':ready,'host':dict(os_release(),architecture=platform.machine(),supported=supported),
            'runtime_version':ctx['version'],'project_version':installed_version(ctx),'components':items,'kernel_policy':sysctls,
            'userns_execution':'未探测；init 后请跑 doctor',
            'resource_enforcement':'未探测；已配置限额仍需真实启动/委托才生效',
            'workspace_runtime':str(Path(ctx['state'])/'lib/version.sh')}


def install_plan(ctx, report, source):
    ids=set((report['host'].get('ID','')+' '+report['host'].get('ID_LIKE','')).split())
    prefix=[] if os.getuid()==0 else ['sudo']
    if ids & {'debian','ubuntu'}:
        commands=[prefix+['apt-get','update'],prefix+['apt-get','install','-y','bubblewrap','python3','libseccomp2','curl','tar','coreutils','util-linux','uidmap','gcc','libc6-dev','git']]
    elif 'alpine' in ids:
        commands=[prefix+['apk','add','bubblewrap','python3','libseccomp','curl','tar','coreutils','util-linux','shadow-uidmap','gcc','musl-dev','git']]
    elif ids & {'fedora','rhel','centos'}:
        commands=[prefix+['dnf','install','-y','bubblewrap','python3','libseccomp','curl','tar','coreutils','util-linux','shadow-utils','gcc','glibc-static','git']]
    elif ids & {'arch','manjaro'}:
        commands=[prefix+['pacman','-S','--needed','bubblewrap','python','libseccomp','curl','tar','coreutils','util-linux','shadow','gcc','git']]
    else:
        commands=[]
    followup=[[ctx['cli'],'--root',ctx['workspace'],'setup','check','--probe','--json']]
    if source:
        # 既有 upgrade 负责校验、停服规则、备份与恢复。
        source=str(real_directory(Path(source)))
        followup += [[str(Path(source)/'bin/capbox'),'--root',ctx['workspace'],'upgrade',action,'--from',source]
                     for action in ('check','apply')]
        followup += [[str(Path(source)/'bin/capbox'),'--root',ctx['workspace'],'upgrade','rollback']]
    return {'kind':'installation_plan','executed':False,'package_commands':commands,'followup_commands':followup,
            'notes':['发行版包装的 bubblewrap 可能低于 0.12.0；请重跑 setup check。',
                     '未改动宿主软件包、sysctl、AppArmor 或项目运行时。',
                     'upgrade apply 前请停掉 services、daemon、tasks 及其他写入者。',
                     '不会自动下载或执行远程安装脚本。']}


def real_directory(path):
    path=path.absolute()
    for part in (path,*path.parents):
        if part.is_symlink():
            raise Failure('路径不能含符号链接')
    if not path.is_dir():
        raise Failure('目录不存在')
    return path.resolve()


def unique(pairs):
    result={}
    for k,v in pairs:
        if k in result: raise Failure('JSON 包含重复键')
        result[k]=v
    return result


def read_file(path, limit):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as f:
        st=os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size>limit:
            raise Failure('制品必须是大小受限的普通文件')
        data=f.read(limit+1)
        if len(data)>limit: raise Failure('制品超过大小限制')
        return data


def digest(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    result=hashlib.sha256()
    with os.fdopen(fd,'rb') as f:
        st=os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size>MAX_ARCHIVE: raise Failure('归档大小或类型不支持')
        while True:
            data=f.read(1024**2)
            if not data: break
            result.update(data)
    return result.hexdigest()


def publish_directory(source,dest):
    # 原子且不覆盖的发布，也避免并发 init/pack 互相踩踏。
    libc=ctypes.CDLL(None,use_errno=True)
    try:rename=libc.renameat2
    except AttributeError as exc:raise Failure('需要支持 renameat2 的 Linux C 库') from exc
    rename.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
    rename.restype=ctypes.c_int
    if rename(-100,os.fsencode(source),-100,os.fsencode(dest),1):
        error=ctypes.get_errno()
        raise OSError(error,os.strerror(error))


def copy_artifact(source,dest):
    fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as incoming, dest.open('xb') as outgoing:
        st=os.fstat(incoming.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size>MAX_ARCHIVE:raise Failure('制品类型或大小不支持')
        remaining=MAX_ARCHIVE
        while True:
            data=incoming.read(min(1024**2,remaining+1))
            if not data:break
            remaining-=len(data)
            if remaining<0:raise Failure('制品大小在读取时超出限制')
            outgoing.write(data)


def validate_launch_directories(root):
    # 常规宿主启动器会创建这些挂载点/配置父目录。在此拒绝链接，
    # 防止导入镜像把宿主侧写入重定向走。
    paths=('etc','proc','sys','dev','tmp','run','root','workspace','var','var/log',
           'var/lib/capbox-data','home','mnt','etc/apk','etc/profile.d','etc/apt/apt.conf.d','etc/ssl/certs')
    for name in paths:
        part=root
        for component in name.split('/'):
            part=part/component
            if part.is_symlink() or (part.exists() and not part.is_dir()):
                raise Failure('rootfs 启动目录不能是链接或普通文件: '+name)


def load_tool(ctx,name):
    spec=importlib.util.spec_from_file_location('capbox_'+name.replace('-','_'),Path(ctx['lib'])/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def portable_config(ctx):
    result={k:v for k,v in ctx['config'].items() if k in PORTABLE}
    if ctx['sources']['ROOTFS_RO']=='default': result.pop('ROOTFS_RO',None)
    if any(item.split(':',1)[0].startswith('/') for item in result.get('FS_BINDS','').split(',') if item):
        raise Failure('可携带环境包不支持绝对宿主 FS_BINDS；请改为工作区相对路径')
    return result


def recipe_text(values):
    return ''.join('CAPBOX_'+k+"='"+v.replace("'","'\\''")+"'\n" for k,v in sorted(values.items()))+'INIT=0\n'


def preflight_tar(path,distro):
    count,total=0,0
    with tarfile.open(path,'r:gz') as archive:
        for member in archive:
            count+=1;total+=max(0,member.size)
            parts=PurePosixPath(member.name).parts
            if (not parts or parts[0]!=distro or member.name.startswith('/') or '..' in parts
                    or not (member.isfile() or member.isdir() or member.issym() or member.islnk())):
                raise Failure('归档包含越界路径、错误根目录或特殊文件')
            if count>200000 or total>MAX_EXPANDED: raise Failure('归档展开后超过 8GiB / 200000 成员限制')
    if not count: raise Failure('归档为空')
    return total


def verify_bundle(ctx,source,expected=None):
    root=real_directory(Path(source))
    if root.is_relative_to(Path(ctx['workspace'])):
        raise Failure('环境包必须位于目标工作区外')
    manifest_bytes=read_file(root/'manifest.json',1024**2)
    if expected is not None and (not re.fullmatch('[0-9a-f]{64}',expected) or hashlib.sha256(manifest_bytes).hexdigest()!=expected):
        raise Failure('环境包 manifest SHA256 不匹配')
    manifest=json.loads(manifest_bytes,object_pairs_hook=unique)
    if not isinstance(manifest,dict) or set(manifest)!={'schema','distro','architecture','runtime_version','config','files'}:
        raise Failure('环境包清单字段无效')
    if manifest['schema']!=BUNDLE_SCHEMA or manifest['distro']!=ctx['config']['DISTRO'] or manifest['architecture']!=platform.machine():
        raise Failure('环境包 schema、发行版或架构与目标不一致')
    config=manifest['config']
    if not isinstance(config,dict) or set(config)-PORTABLE or not all(isinstance(v,str) for v in config.values()):
        raise Failure('环境包配置字段无效')
    if not isinstance(manifest['files'],dict) or set(manifest['files'])!=set(FILES): raise Failure('制品清单不完整')
    for name,sha in manifest['files'].items():
        if not isinstance(sha,str) or not re.fullmatch('[0-9a-f]{64}',sha) or digest(root/name)!=sha:
            raise Failure('环境包校验失败: '+name)
    read_file(root/'package.lock',4*1024**2)
    if config.get('DISTRO')!=manifest['distro']:raise Failure('配方发行版与归档不一致')
    packages=load_tool(ctx,'package-lock').load(root/'package.lock',manifest['distro'],manifest['architecture'])
    if read_file(root/'recipe.env',1024**2).decode()!=recipe_text(config): raise Failure('配方与清单配置不一致')
    success(cli(ctx,'recipe','check',root/'recipe.env'),'环境包配方无效')
    preflight_tar(root/'rootfs.tar.gz',manifest['distro'])
    return root,manifest,packages


def pack(ctx,args):
    source=real_directory(Path(ctx['rootfs']))
    upper=Path(ctx['state'])/'run/overlay/active/upper'
    if upper.is_symlink() or (upper.exists() and any(upper.iterdir())):
        raise Failure('环境包首版不支持已有非空 overlay upper')
    dest=Path(args.path).absolute();parent=real_directory(dest.parent)
    if dest.exists() or dest.is_symlink() or dest.resolve().is_relative_to(Path(ctx['workspace'])):
        raise Failure('输出必须是工作区外尚不存在的目录')
    config=portable_config(ctx)
    if args.recipe:
        recipe=json.loads(success(cli(ctx,'recipe','export',Path(args.recipe).absolute()),'配方校验失败'))['values']
        if set(recipe)-PORTABLE-{'INIT','PACKAGES'}: raise Failure('配方含不便携或可能含凭据的宿主设置')
        for k,v in recipe.items():
            if k in PORTABLE and config.get(k)!=v: raise Failure('配方与当前环境配置不一致: '+k)
    private=Path(tempfile.mkdtemp(prefix='.capbox-bundle-',dir=parent))
    try:
        lock=Path(success(cli(ctx,'image','lock','save'),'无法保存包锁').decode().strip())
        shutil.copyfile(lock,private/'package.lock')
        if args.recipe:
            success(cli(ctx,'recipe','check','--locked',private/'package.lock',Path(args.recipe).absolute()),
                    '配方需要的软件包不在当前锁中')
        (private/'recipe.env').write_text(recipe_text(config))
        success(cli(ctx,'recipe','check',private/'recipe.env'),'快照配置校验失败')
        subprocess.run(['tar','--numeric-owner','-czf',str(private/'rootfs.tar.gz'),'-C',str(source.parent),source.name],
                       check=True,capture_output=True,timeout=300)
        preflight_tar(private/'rootfs.tar.gz',ctx['config']['DISTRO'])
        manifest={'schema':BUNDLE_SCHEMA,'distro':ctx['config']['DISTRO'],'architecture':platform.machine(),
                  'runtime_version':ctx['version'],'config':config,'files':{name:digest(private/name) for name in FILES}}
        (private/'manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
        for file in private.iterdir():file.chmod(0o600)
        # 目标仍须不存在；rename 不能替换已有内容的目录。
        publish_directory(private,dest)
        json_output({'kind':'bundle_packed','path':str(dest),'manifest_sha256':digest(dest/'manifest.json'),
                     'files':manifest['files']})
    finally:
        if private.exists():shutil.rmtree(private)


def restore(ctx,args):
    # 暂存全部输入并校验这份不可变副本，而非 guest 可写路径。
    parent=real_directory(Path(ctx['state'])/'os')
    target=parent/ctx['config']['DISTRO']
    if target.exists() or target.is_symlink():raise Failure('restore 只接受不存在的 rootfs，不覆盖已有环境')
    source,manifest,_packages=verify_bundle(ctx,args.path,args.manifest_sha256)
    pinned=hashlib.sha256((json.dumps(manifest,sort_keys=True)).encode()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='capbox-bundle-') as temporary:
        private=Path(temporary);bundle=private/'bundle';bundle.mkdir()
        for name in (*FILES,'manifest.json'):copy_artifact(source/name,bundle/name)
        _root,staged_manifest,_packages=verify_bundle(ctx,bundle,args.manifest_sha256)
        if hashlib.sha256(json.dumps(staged_manifest,sort_keys=True).encode()).hexdigest()!=pinned:
            raise Failure('复制期间环境包清单发生变化')
        manifest=staged_manifest
        # 用现有带过滤的镜像导入器解包，落在目标文件系统上。
        stage=Path(tempfile.mkdtemp(prefix='.bundle-',dir=parent))
        promoted=False
        try:
            command='source "$1/common.sh"; source "$1/image.sh"; _image_extract_archive "$2" "$3"'
            p=subprocess.run(['bash','-c',command,'capbox-bundle',ctx['lib'],str(bundle/'rootfs.tar.gz'),str(stage)],
                             env=environment(ctx),capture_output=True,timeout=300)
            success(p,'安全解包失败')
            if not (stage/manifest['distro']).is_dir() or (stage/manifest['distro']).is_symlink():
                raise Failure('归档缺少真实 rootfs 目录')
            validate_launch_directories(stage/manifest['distro'])
            publish_directory(stage/manifest['distro'],target);promoted=True
            verify_env=environment(ctx)
            verify_env.update(CAPBOX_SECURITY_PROFILE='untrusted',CAPBOX_NET='none',CAPBOX_IDMAP='off')
            success(cli(ctx,'image','lock','verify',bundle/'package.lock',env=verify_env,timeout=120),'恢复后包清单不匹配')
            # 钉住的纯数据锁便于后续漂移检查。
            state=real_directory(Path(ctx['state'])/'state')
            lock=state/'package.lock'
            if lock.is_symlink():raise Failure('目标包锁不能是符号链接')
            staged=state/('.bundle-lock-'+uuid.uuid4().hex)
            staged.write_bytes(read_file(bundle/'package.lock',4*1024**2));staged.chmod(0o600)
            os.replace(staged,lock)
            json_output({'kind':'bundle_restored','rootfs':str(target),'config_applied':False,
                         'notes':'目标策略保持不变。显式应用配置前请审阅 recipe.env。'})
        except BaseException:
            if promoted:shutil.rmtree(target)
            raise
        finally:
            shutil.rmtree(stage)


def main():
    p=argparse.ArgumentParser(prog='capbox',description='宿主安装计划、离线环境包与 MCP')
    families=p.add_subparsers(dest='family',required=True)
    setup=families.add_parser('setup');actions=setup.add_subparsers(dest='action',required=True)
    for action in ('check','plan'):
        s=actions.add_parser(action);s.add_argument('--json',action='store_true');s.add_argument('--probe',action='store_true')
        if action=='plan':s.add_argument('--from',dest='source')
    bundle=families.add_parser('bundle');actions=bundle.add_subparsers(dest='action',required=True)
    for action in ('pack','verify','check','restore'):
        s=actions.add_parser(action);s.add_argument('path');s.add_argument('--json',action='store_true')
        if action=='pack':s.add_argument('--recipe')
        else:s.add_argument('--manifest-sha256')
    defaults=mcp_defaults()
    mcp=families.add_parser('mcp')
    mcp.add_argument('action',choices=['serve'])
    mcp.add_argument('--profile',choices=list(defaults.ALLOWED_PROFILES),default=defaults.DEFAULT_PROFILE,
                     help='安全配置档（默认: %(default)s)')
    mcp.add_argument('--net',choices=list(defaults.ALLOWED_NET),default=defaults.DEFAULT_NET,
                     help='网络模式（默认: %(default)s；拒绝 open）')
    mcp.add_argument('--workspace-mode',choices=list(defaults.ALLOWED_WORKSPACE_MODES),
                     default=defaults.DEFAULT_WORKSPACE_MODE,
                     help='任务工作区（默认: %(default)s)')
    mcp.add_argument('--max-timeout',type=int,default=defaults.DEFAULT_MAX_TIMEOUT,
                     help='任务超时上限秒数（默认: %(default)s)')
    args=p.parse_args();ctx=context()
    if args.family=='mcp':
        mcp_ctx=dict(ctx,config=dict(ctx['config'],PROXY=''))
        return load_tool(ctx,'mcp-stdio').serve(mcp_ctx,args,lambda command: cli(mcp_ctx,*command,timeout=300))
    if args.family=='setup':
        report=readiness(ctx,args.probe)
        if args.action=='plan':report=install_plan(ctx,report,args.source)
        json_output(report,human=not args.json)
        return 0 if args.action=='plan' or report['dependencies_ready'] else 1
    if args.action=='pack':pack(ctx,args)
    elif args.action=='restore':restore(ctx,args)
    else:
        root,manifest,packages=verify_bundle(ctx,args.path,args.manifest_sha256)
        differences={k:{'locked':v,'actual':ctx['config'].get(k)} for k,v in manifest['config'].items() if ctx['config'].get(k)!=v}
        package_ok=None
        if args.action=='check':
            package_ok=cli(ctx,'image','lock','verify',root/'package.lock',timeout=120).returncode==0
        json_output({'kind':'bundle_'+args.action,'integrity':'verified','package_count':len(packages),
                     'configuration_drift':differences,'packages_match':package_ok})
        return 1 if args.action=='check' and (differences or not package_ok) else 0
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:sys.exit(130)
    except Failure as exc:
        print('[capbox] '+str(exc),file=sys.stderr);sys.exit(exc.code)
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError,tarfile.TarError) as exc:
        print('[capbox] 环境工具操作失败: '+type(exc).__name__+': '+str(exc),file=sys.stderr);sys.exit(1)

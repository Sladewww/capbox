#!/usr/bin/env python3
"""Public CLI contracts, including real guest execution when a rootfs is supplied."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
ROOTFS = Path(os.environ.get('CAPBOX_TEST_ROOTFS', REPO / 'os/alpine'))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cba-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.ws = self.base / 'ws'
        self.ws.mkdir()
        runtime = self.base / 'r'
        runtime.mkdir(mode=0o700)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('CAPBOX_', '_CAPBOX_'))}
        self.env.update(XDG_RUNTIME_DIR=str(runtime), CAPBOX_IDMAP='off', CAPBOX_NET='none',
                        CAPBOX_SECURITY_PROFILE='untrusted', CAPBOX_OVERLAY='off')
        self.cli = [str(REPO / 'bin/capbox'), '--root', str(self.ws)]
        self.run_cli('bootstrap', check=True)

    def run_cli(self, *args, check=False):
        return subprocess.run(self.cli + list(args), env=self.env, capture_output=True,
                              text=True, timeout=45, check=check)


class PolicyTests(Fixture):
    def test_sources_override_without_mutation(self):
        self.run_cli('config', 'set', 'CAPBOX_NET', 'open', check=True)
        d=json.loads(self.run_cli('policy','show').stdout)
        self.assertEqual(d['values']['NET'], {'value':'none','source':'env'})
        d=json.loads(self.run_cli('policy','show','--net','restricted').stdout)
        self.assertEqual(d['values']['NET'], {'value':'restricted','source':'command'})
        self.assertEqual(self.run_cli('config','get','CAPBOX_NET').stdout.strip(),'none')

    def test_strict_defaults(self):
        d=json.loads(self.run_cli('policy','show','--profile','strict').stdout)
        self.assertEqual(d['values']['ROOTFS_RO']['value'],'1')
        self.assertEqual(d['values']['LANDLOCK']['value'],'on')

    def test_network_preview_matches_proxy_host_port_and_ip_rules(self):
        self.env['CAPBOX_NET_ALLOW']='example.com'
        self.assertEqual(self.run_cli('policy','check','https://example.com/').returncode,1)
        d=json.loads(self.run_cli('policy','check','--net','restricted','https://example.com/').stdout)
        self.assertEqual(d['decision'],'conditional')
        self.assertEqual(d['matched_rules'],['example.com'])
        self.assertFalse(d['connectivity_tested'])
        for url in ['https://example.com:8443/','http://127.0.0.1/']:
            self.assertEqual(self.run_cli('policy','check','--net','restricted',url).returncode,1)
        self.env['CAPBOX_NET_ALLOW']='127.0.0.1'
        d=json.loads(self.run_cli('policy','check','--net','restricted','--resolve','http://127.0.0.1/').stdout)
        self.assertEqual(d['decision'],'allow')

    def test_bad_ids_and_secret_urls(self):
        r=self.run_cli('policy','check','https://user:fixture-secret@example.com/')
        self.assertEqual(r.returncode,2)
        self.assertNotIn('fixture-secret',r.stdout+r.stderr)
        self.assertEqual(self.run_cli('task','status','../../etc/passwd').returncode,2)


@unittest.skipUnless((ROOTFS/'bin/sh').is_symlink() or (ROOTFS/'bin/sh').exists(),
                     'set CAPBOX_TEST_ROOTFS for real guest task tests')
class TaskTests(Fixture):
    def setUp(self):
        super().setUp()
        shutil.copytree(ROOTFS,self.ws/'.capbox/os/alpine',symlinks=True)
        self.tasks=[]
        self.addCleanup(self.stop_tasks)

    def stop_tasks(self):
        for task in self.tasks:
            self.run_cli('task','cancel',task)
            self.run_cli('task','wait',task,'--timeout','5')
            self.run_cli('task','rm',task)

    def start(self,*args):
        r=self.run_cli('task','start',*args)
        self.assertEqual(r.returncode,0,r.stderr)
        task=json.loads(r.stdout)['task_id'];self.tasks.append(task)
        return task

    def wait(self,task,code=0,timeout=15):
        r=self.run_cli('task','wait',task,'--timeout',str(timeout),'--json')
        self.assertEqual(r.returncode,code,r.stdout+r.stderr)
        return json.loads(r.stdout)

    def git(self,*args):
        subprocess.run(['git','-C',str(self.ws),*args],check=True,capture_output=True)

    def init_git(self):
        self.git('init','-q')
        (self.ws/'hello.txt').write_text('base\n')
        (self.ws/'.env').write_text('fixture-secret\n')
        (self.ws/'.gitignore').write_text('.capbox/\n.env\n')
        self.git('add','hello.txt','.gitignore')
        self.git('add','-f','.env')

    def test_reconnect_cursors_streams_and_exit(self):
        task=self.start('--','sh','-c','printf abc; sleep 0.5; printf def; printf err >&2; exit 7')
        self.assertEqual(self.wait(task,7)['status'],'failed')
        a=json.loads(self.run_cli('task','logs',task,'--limit','2','--json').stdout)
        b=json.loads(self.run_cli('task','logs',task,'--offset',str(a['next_offset']),'--json').stdout)
        self.assertEqual(base64.b64decode(a['data_base64'])+base64.b64decode(b['data_base64']),b'abcdef')
        r=self.run_cli('task','attach',task,'--stdout-offset','3','--json')
        events=[json.loads(line) for line in r.stdout.splitlines()]
        stdout=b''.join(base64.b64decode(e['data_base64']) for e in events if e.get('type')=='output' and e['stream']=='stdout')
        stderr=b''.join(base64.b64decode(e['data_base64']) for e in events if e.get('type')=='output' and e['stream']=='stderr')
        self.assertEqual(stdout,b'def');self.assertIn(b'err',stderr)
        self.assertEqual(events[-1]['exit_code'],7)

    def test_log_cursor_past_eof_is_marked(self):
        task=self.start('--','sh','-c','printf abc')
        self.wait(task)
        r=self.run_cli('task','logs',task,'--offset','100','--json')
        self.assertEqual(r.returncode,0,r.stderr)
        d=json.loads(r.stdout)
        self.assertTrue(d['cursor_past_eof'])
        self.assertTrue(d['eof'])
        self.assertEqual(d['size'],3)
        self.assertIn('next_offset', d['hint'])

    def test_wait_timeout_includes_hint(self):
        task=self.start('--','sleep','30')
        r=self.run_cli('task','wait',task,'--timeout','1','--json')
        self.assertEqual(r.returncode,124)
        d=json.loads(r.stdout)
        self.assertEqual(d['kind'],'wait_timeout')
        self.assertIn('cancel', d['hint'])
        self.run_cli('task','cancel',task)
        self.wait(task,143,timeout=5)

    def test_wait_timeout_cancel_and_no_cross_task_kill(self):
        other=self.start('--','sleep','2');task=self.start('--','sleep','8')
        self.assertEqual(self.run_cli('task','wait',task,'--timeout','1').returncode,124)
        self.assertEqual(json.loads(self.run_cli('task','status',task).stdout)['status'],'running')
        self.assertNotEqual(self.run_cli('task','rm',task).returncode,0)
        self.run_cli('task','cancel',task,check=True)
        self.assertEqual(self.wait(task,143,timeout=3)['status'],'cancelled')
        self.assertEqual(self.wait(other)['status'],'succeeded')

    def test_execution_timeout_and_bounded_binary_logs(self):
        task=self.start('--timeout','1','--','sleep','30')
        self.assertEqual(self.wait(task,124)['status'],'timed_out')
        task=self.start('--max-output-bytes','5','--','sh','-c','printf "1234567890"')
        d=self.wait(task)
        self.assertEqual(d['output_bytes']['stdout'],5)
        self.assertEqual(d['dropped_bytes']['stdout'],5)
        self.assertEqual(self.run_cli('task','logs',task).stdout,'12345')

    def test_launch_failure_is_nonzero(self):
        task=self.start('--','/no-such-command')
        r=self.run_cli('task','wait',task,'--timeout','10')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(json.loads(r.stdout)['status'],'failed')

    def test_isolation_diff_binary_deletion_and_origin_conflict(self):
        self.init_git()
        task=self.start('--isolate','--','sh','-c',
            'test ! -e /workspace/.env && test ! -e /workspace/.git && '
            'echo task > /workspace/hello.txt; printf "\\000binary" > /workspace/new.bin; '
            'rm /workspace/.gitignore; echo private > /etc/task-private')
        self.wait(task)
        self.assertEqual((self.ws/'hello.txt').read_text(),'base\n')
        self.assertFalse((self.ws/'.capbox/os/alpine/etc/task-private').exists())
        r=self.run_cli('task','diff',task,'--json');self.assertEqual(r.returncode,0,r.stderr)
        d=json.loads(r.stdout);patch=base64.b64decode(d['patch_base64'])
        self.assertIn('new.bin',d['changed_files'])
        self.assertIn(b'GIT binary patch',patch);self.assertIn(b'deleted file mode',patch)
        self.assertNotIn(b'fixture-secret',patch)
        self.assertIn('从不自动应用', d.get('notes', ''))
        (self.ws/'hello.txt').write_text('concurrent-change\n')
        d=json.loads(self.run_cli('task','diff',task,'--json').stdout)
        self.assertIn('hello.txt',d['origin_changed'])

    def test_guest_symlink_rejected_by_diff(self):
        self.init_git()
        task=self.start('--isolate','--','sh','-c','ln -s /etc/passwd /workspace/leak')
        self.wait(task)
        r=self.run_cli('task','diff',task,'--json')
        self.assertNotEqual(r.returncode,0);self.assertNotIn('root:',r.stdout)

    def test_origin_ancestor_symlink_is_a_conflict(self):
        self.init_git()
        (self.ws/'sub').mkdir()
        (self.ws/'sub/file').write_text('baseline')
        self.git('add','sub/file')
        task=self.start('--isolate','--','true');self.wait(task)
        outside=self.base/'outside';outside.mkdir();(outside/'file').write_text('baseline')
        shutil.rmtree(self.ws/'sub');(self.ws/'sub').symlink_to(outside,target_is_directory=True)
        d=json.loads(self.run_cli('task','diff',task,'--json').stdout)
        self.assertIn('sub/file',d['origin_changed'])

    def test_dead_controller_is_lost_and_child_stops(self):
        task=self.start('--','sh','-c','sleep 3; echo survived > /workspace/orphan-marker')
        private=subprocess.check_output(['bash','-c',
            'export CAPBOX_DIR="$1/.capbox" CAPBOX_WORKSPACE="$1"; '
            'source "$2/lib/common.sh"; _capbox_host_state_dir',
            'test',str(self.ws),str(REPO)],env=self.env,text=True)
        job=Path(private)/'tasks'/task
        state=json.loads((job/'state.json').read_text())
        os.kill(state['worker']['pid'],9)
        # Parent-death handling must stop the CLI/bwrap even across client disconnect.
        import time
        time.sleep(3.5)
        self.assertFalse((self.ws/'orphan-marker').exists())
        d=json.loads(self.run_cli('task','status',task).stdout)
        self.assertEqual(d['status'],'lost')
        self.assertNotEqual(self.run_cli('task','wait',task).returncode,0)
        self.assertNotEqual(self.run_cli('task','rm',task).returncode,0)
        self.tasks.remove(task)


    def test_running_task_blocks_runtime_upgrade(self):
        task=self.start('--','sleep','10')
        r=self.run_cli('upgrade','apply','--from',str(REPO))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('task',r.stderr)
        self.run_cli('task','cancel',task,check=True);self.wait(task,143)

    def test_parallel_restricted_tasks_have_private_network_sessions(self):
        import time
        self.env['CAPBOX_NET_ALLOW']='example.com'
        tasks=[self.start('--net','restricted','--','sleep','10') for _ in range(2)]
        private=subprocess.check_output(['bash','-c',
            'export CAPBOX_DIR="$1/.capbox" CAPBOX_WORKSPACE="$1"; '
            'source "$2/lib/common.sh"; _capbox_host_state_dir',
            'test',str(self.ws),str(REPO)],env=self.env,text=True)
        import hashlib
        sockets=[Path(private)/'net'/(hashlib.sha256(('task-'+task).encode()).hexdigest()[:32]+'.sock') for task in tasks]
        deadline=time.monotonic()+5
        while time.monotonic()<deadline and not all(path.is_socket() for path in sockets):
            time.sleep(0.05)
        self.assertTrue(all(path.is_socket() for path in sockets))
        self.run_cli('task','cancel',tasks[0],check=True);self.wait(tasks[0],143)
        self.assertTrue(sockets[1].is_socket())
        self.assertEqual(json.loads(self.run_cli('task','status',tasks[1]).stdout)['status'],'running')
        self.run_cli('task','cancel',tasks[1],check=True);self.wait(tasks[1],143)


    def test_overlay_upper_is_merged_into_private_rootfs(self):
        self.init_git()
        upper=self.ws/'.capbox/run/overlay/active/upper'
        upper.mkdir(parents=True)
        (upper/'installed-tool').write_text('fixture-from-upper')
        host_marker=(upper/'installed-tool').read_text()
        task=self.start('--isolate','--','sh','-c','test -f /installed-tool && grep -q fixture-from-upper /installed-tool && echo ok > /workspace/merged.txt')
        self.wait(task)
        self.assertEqual((self.ws/'merged.txt').read_text() if (self.ws/'merged.txt').exists() else '','')
        # guest wrote into private isolate workspace; export via diff presence
        d=json.loads(self.run_cli('task','diff',task,'--json').stdout)
        self.assertIn('merged.txt',d['changed_files'])
        # host upper must remain unchanged
        self.assertEqual((upper/'installed-tool').read_text(),host_marker)
        self.assertFalse((self.ws/'.capbox/os/alpine/installed-tool').exists())


    def test_non_git_isolate_and_diff(self):
        (self.ws/'app.txt').write_text('plain\n')
        (self.ws/'.env').write_text('fixture-secret\n')
        task=self.start('--isolate','--','sh','-c','test -f /workspace/app.txt && test ! -e /workspace/.env && echo from-task > /workspace/out.txt')
        self.wait(task)
        d=json.loads(self.run_cli('task','diff',task,'--json').stdout)
        self.assertIn('out.txt',d['changed_files'])
        self.assertNotIn(b'fixture-secret',base64.b64decode(d['patch_base64']))


    def test_dirty_git_includes_untracked(self):
        self.init_git()
        (self.ws/'scratch.txt').write_text('untracked-before\n')
        task=self.start('--isolate','--','sh','-c','test -f /workspace/scratch.txt && echo edited >> /workspace/scratch.txt && echo brand-new > /workspace/fresh.txt')
        self.wait(task)
        d=json.loads(self.run_cli('task','diff',task,'--json').stdout)
        self.assertIn('scratch.txt',d['changed_files'])
        self.assertIn('fresh.txt',d['changed_files'])


    def test_source_symlink_rejected(self):
        self.init_git();(self.ws/'hello.txt').unlink();(self.ws/'hello.txt').symlink_to('/etc/passwd')
        r=self.run_cli('task','start','--isolate','--','true')
        self.assertNotEqual(r.returncode,0);self.assertIn('符号链接',r.stderr)


if __name__=='__main__':
    unittest.main()

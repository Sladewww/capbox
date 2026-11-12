#!/usr/bin/env python3
"""Readiness, portable environment and real stdio MCP behavior contracts."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import time
import unittest
from test_agent_workflows import Fixture, ROOTFS, REPO
os.environ['CAPBOX_LANG'] = 'zh'
import importlib.util
from types import SimpleNamespace


def load_module(name, relative):
    spec = importlib.util.spec_from_file_location(name, REPO / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MCP_DEFAULTS = load_module('capbox_mcp_defaults', 'lib/mcp-defaults.py')
MCP_STDIO = load_module('capbox_mcp_stdio', 'lib/mcp-stdio.py')
ENVKIT = load_module('capbox_envkit_runtime', 'lib/envkit-runtime.py')


def request(identifier,method,params=None):
    result={'jsonrpc':'2.0','method':method}
    if identifier is not None:result['id']=identifier
    if params is not None:result['params']=params
    return result


def initialization():
    return [request(1,'initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}}),
            request(None,'notifications/initialized')]


class SetupTests(Fixture):
    def test_check_reports_dependencies_without_claiming_guest_execution(self):
        before=list(self.ws.rglob('config.env'))
        r=self.run_cli('setup','check','--json');d=json.loads(r.stdout)
        self.assertIn('dependencies_ready',d)
        self.assertIn('not_probed',d['userns_execution'])
        self.assertEqual(before,list(self.ws.rglob('config.env')))
        self.assertNotIn('rootfs', [p.name for p in self.ws.iterdir()])

    def test_plan_never_executes_host_installers(self):
        r=self.run_cli('setup','plan','--from',str(REPO),'--json')
        self.assertEqual(r.returncode,0,r.stderr)
        d=json.loads(r.stdout)
        self.assertFalse(d['executed']);self.assertTrue(d['followup_commands'])
        self.assertFalse((self.ws/'.capbox/os/alpine').exists())

    def test_setup_uses_new_template_for_an_older_project(self):
        (self.ws/'.capbox/lib/envkit.sh').unlink()
        r=self.run_cli('setup','plan','--json')
        self.assertEqual(r.returncode,0,r.stderr)

    def test_recipe_export_is_validated_data(self):
        recipe=self.ws/'project.recipe';recipe.write_text('DISTRO=alpine\nNET=none\nPACKAGES=curl\n')
        r=self.run_cli('recipe','export',str(recipe));self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['values']['PACKAGES'],'curl')
        recipe.write_text('UNKNOWN_KEY=value\n')
        self.assertNotEqual(self.run_cli('recipe','export',str(recipe)).returncode,0)


class MCPTests(Fixture):
    def exchange(self,messages,*options):
        data=''.join(json.dumps(m)+'\n' if not isinstance(m,bytes) else m.decode() for m in messages)
        r=subprocess.run(self.cli+['mcp','serve',*options],env=self.env,input=data,text=True,capture_output=True,timeout=45)
        self.assertEqual(r.returncode,0,r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def test_handshake_notifications_and_available_tools(self):
        messages=initialization()+[request(2,'tools/list'),request(3,'tools/call',{'name':'capbox_policy','arguments':{}})]
        out=self.exchange(messages)
        self.assertEqual(len(out),3)
        self.assertEqual(out[0]['result']['protocolVersion'],'2025-11-25')
        names={x['name'] for x in out[1]['result']['tools']}
        self.assertEqual(names,{'capbox_execute','capbox_status','capbox_logs','capbox_cancel','capbox_diff','capbox_policy'})
        self.assertEqual(out[2]['result']['structuredContent']['values']['NET']['value'],'none')
        self.assertFalse(names & {'setup','upgrade','config'})

    def test_invalid_arguments_cannot_change_fixed_workspace_or_policy(self):
        bad=[{'argv':['true'],'root':'/'},{'argv':['true'],'net':'open'},
             {'argv':['true'],'timeout':True},{'argv':['true'],'timeout':0},
             {'argv':['true'],'cwd':'/workspace/../root'},{'argv':['true'],'timeout':601}]
        messages=initialization()+[request(i+2,'tools/call',{'name':'capbox_execute','arguments':a}) for i,a in enumerate(bad)]
        out=self.exchange(messages)
        self.assertTrue(all(x['error']['code']==-32602 for x in out[1:]))
        self.assertEqual(json.loads(self.run_cli('task','list').stdout)['tasks'],[])

    def test_parse_error_unknown_method_bad_ids_and_init_order(self):
        bad_id=request(4,'ping');bad_id['id']={'invalid':True}
        out=self.exchange([b'{bad json}\n',request(1,'tools/list'),bad_id,*initialization(),request(8,'no-such-method')])
        self.assertEqual(out[0]['error']['code'],-32700)
        self.assertEqual(out[1]['error']['code'],-32000)
        self.assertIsNone(out[2]['id'])
        self.assertEqual(out[-1]['error']['code'],-32601)

    def test_non_json_constants_duplicate_keys_and_huge_integers_are_rejected(self):
        bad=[b'{"jsonrpc":"2.0","id":NaN,"method":"ping"}\n',
             b'{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/list"}\n',
             b'{"jsonrpc":"2.0","id":'+b'9'*100+b',"method":"ping"}\n']
        out=self.exchange(bad+initialization()+[request(2,'ping')])
        self.assertTrue(all(x['error']['code']==-32700 for x in out[:3]))
        self.assertEqual(out[-1]['result'],{})


    def test_oversize_message_is_bounded_and_stream_resynchronizes(self):
        huge=b'{"x":"'+b'x'*(1024*1024)+b'"}\n'
        out=self.exchange([huge,*initialization(),request(2,'ping')])
        self.assertEqual(out[0]['error']['code'],-32700)
        self.assertEqual(out[-1]['result'],{})


    def test_cli_defaults_lock_daily_trust_boundary(self):
        parser = ENVKIT.build_mcp_parser()
        args = parser.parse_args(['serve'])
        self.assertEqual(args.profile, MCP_DEFAULTS.DEFAULT_PROFILE)
        self.assertEqual(args.net, MCP_DEFAULTS.DEFAULT_NET)
        self.assertEqual(args.workspace_mode, MCP_DEFAULTS.DEFAULT_WORKSPACE_MODE)
        self.assertEqual(args.max_timeout, MCP_DEFAULTS.DEFAULT_MAX_TIMEOUT)
        self.assertEqual(args.profile, 'untrusted')
        self.assertEqual(args.net, 'none')
        self.assertEqual(args.workspace_mode, 'isolated')
        self.assertEqual(args.max_timeout, 600)
        self.assertEqual(MCP_DEFAULTS.MAX_OUTPUT_BYTES, 8 * 1024 * 1024)
        import contextlib, io
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                parser.parse_args(['serve', '--net', 'open'])

    def test_default_execute_pins_isolate_untrusted_none_and_8mib(self):
        calls = []
        class Proc:
            returncode = 0
            stdout = '{"task_id":"' + ('0' * 32) + '","state":"running"}'
        def invoke(command):
            calls.append(command)
            return Proc()
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1'}, args, invoke).call('capbox_execute', {'argv': ['true']})
        self.assertFalse(result['isError'])
        command = calls[0]
        self.assertEqual(command[:2], ['task', 'start'])
        self.assertIn('--isolate', command)
        self.assertEqual(command[command.index('--profile') + 1], 'untrusted')
        self.assertEqual(command[command.index('--net') + 1], 'none')
        self.assertEqual(command[command.index('--max-output-bytes') + 1], str(MCP_DEFAULTS.MAX_OUTPUT_BYTES))
        self.assertNotIn('open', command)

    def test_shared_mode_is_opt_in_and_omits_isolate(self):
        calls = []
        class Proc:
            returncode = 0
            stdout = '{"task_id":"' + ('0' * 32) + '","state":"running"}'
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='shared', max_timeout=600)
        MCP_STDIO.Server({'version': '0.5.1'}, args, lambda c: calls.append(c) or Proc()).call(
            'capbox_execute', {'argv': ['true']})
        self.assertNotIn('--isolate', calls[0])

    def test_tool_schema_rejects_policy_and_root_overrides(self):
        schema = next(t['inputSchema'] for t in MCP_STDIO.tools(600) if t['name'] == 'capbox_execute')
        for key in ('root', 'profile', 'net', 'workspace_mode', 'max_output_bytes', 'isolate'):
            self.assertNotIn(key, schema['properties'])
        diff = next(t for t in MCP_STDIO.tools(600) if t['name'] == 'capbox_diff')
        self.assertIn('从不', diff['description'])

    def test_handshake_advertises_fixed_defaults_in_instructions(self):
        out = self.exchange(initialization())
        instructions = out[0]['result']['instructions']
        self.assertIn('isolated/untrusted/none', instructions)
        self.assertIn('不能抬高策略', instructions)

    def test_policy_tool_reports_mcp_fixed_block(self):
        out = self.exchange(initialization() + [request(2, 'tools/call', {'name': 'capbox_policy', 'arguments': {}})])
        data = out[1]['result']['structuredContent']
        self.assertEqual(data['values']['NET']['value'], 'none')
        self.assertEqual(data['mcp']['workspace_mode'], 'isolated')
        self.assertEqual(data['mcp']['profile'], 'untrusted')
        self.assertEqual(data['mcp']['net'], 'none')
        self.assertEqual(data['mcp']['max_output_bytes'], 8 * 1024 * 1024)
        self.assertTrue(data['mcp']['tools_cannot_raise_policy'])



    def test_tools_list_cursor_error_explains_single_page(self):
        out = self.exchange(initialization() + [request(2, 'tools/list', {'cursor': '1'})])
        err = out[1]['error']
        self.assertEqual(err['code'], -32602)
        self.assertIn('省略 cursor', err['message'])
        self.assertIn('完整工具列表', err['message'])

    def test_status_timed_out_surfaces_next_step_text(self):
        class Proc:
            returncode = 0
            stdout = json.dumps({
                'schema': 'capbox.agent.v1', 'task_id': 'a' * 32,
                'status': 'timed_out', 'exit_code': 124,
                'hint': '任务执行超时',
            })
            stderr = b''
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1'}, args, lambda c: Proc()).call(
            'capbox_status', {'task_id': 'a' * 32})
        self.assertFalse(result['isError'])
        text = result['content'][0]['text']
        self.assertIn('执行超时', text)
        self.assertIn('capbox_logs', text)
        self.assertEqual(result['structuredContent']['status'], 'timed_out')

    def test_logs_past_eof_surfaces_byte_cursor_hint(self):
        class Proc:
            returncode = 0
            stdout = json.dumps({
                'task_id': 'b' * 32, 'stream': 'stdout', 'offset': 99, 'next_offset': 99,
                'data_base64': '', 'size': 3, 'eof': True, 'cursor_past_eof': True,
                'hint': '日志游标超出文件末尾',
            })
            stderr = b''
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1'}, args, lambda c: Proc()).call(
            'capbox_logs', {'task_id': 'b' * 32, 'offset': 99})
        text = result['content'][0]['text']
        self.assertIn('文件末尾', text)
        self.assertIn('next_offset', text)
        self.assertTrue(result['structuredContent']['cursor_past_eof'])

    def test_cli_failure_uses_sanitized_stderr_not_opaque_setup(self):
        class Proc:
            returncode = 2
            stdout = b'not-json'
            stderr = '[capbox] 找不到 task ID\n'.encode()
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1'}, args, lambda c: Proc()).call(
            'capbox_status', {'task_id': 'c' * 32})
        self.assertTrue(result['isError'])
        text = result['content'][0]['text']
        self.assertIn('找不到 task ID', text)
        self.assertNotIn('check local setup', text.lower())

    def test_diff_tool_still_never_auto_applies(self):
        diff = next(t for t in MCP_STDIO.tools(600) if t['name'] == 'capbox_diff')
        self.assertIn('从不', diff['description'])
        class Proc:
            returncode = 2
            stdout = b''
            stderr = '[capbox] diff 只支持已结束且非 lost 的隔离任务\n'.encode()
        args = SimpleNamespace(profile='untrusted', net='none', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1'}, args, lambda c: Proc()).call(
            'capbox_diff', {'task_id': 'd' * 32})
        self.assertTrue(result['isError'])
        self.assertIn('从不自动应用', result['content'][0]['text'])

    def test_restricted_policy_mentions_unbound_credential_next_step(self):
        class Proc:
            returncode = 0
            stdout = json.dumps({'schema': 'capbox.agent.v1', 'values': {'NET': {'value': 'restricted'}}})
            stderr = b''
        args = SimpleNamespace(profile='untrusted', net='restricted', workspace_mode='isolated', max_timeout=600)
        result = MCP_STDIO.Server({'version': '0.5.1', 'config': {'NET_ALLOW': 'api.openai.com'}},
                                 args, lambda c: Proc()).call('capbox_policy', {})
        note = result['structuredContent']['mcp']['credential_note']
        self.assertIn('secret set', note)
        self.assertIn('占位符', note)



@unittest.skipUnless((ROOTFS/'bin/sh').is_symlink() or (ROOTFS/'bin/sh').exists(),'real rootfs required')
class BundleTests(Fixture):
    def setUp(self):
        super().setUp();shutil.copytree(ROOTFS,self.ws/'.capbox/os/alpine',symlinks=True)
        self.bundle=self.base/'export'

    def pack(self):
        r=self.run_cli('bundle','pack',str(self.bundle));self.assertEqual(r.returncode,0,r.stderr)
        return json.loads(r.stdout)

    def test_round_trip_offline_restore_and_config_drift(self):
        self.pack()
        self.assertEqual(self.run_cli('bundle','check',str(self.bundle)).returncode,0)
        self.env['CAPBOX_NET']='open'
        d=json.loads(self.run_cli('bundle','check',str(self.bundle)).stdout)
        self.assertIn('NET',d['configuration_drift'])
        self.env['CAPBOX_NET']='none'
        target=self.base/'target';target.mkdir()
        command=[str(REPO/'bin/capbox'),'--root',str(target)]
        subprocess.run(command+['bootstrap'],env=self.env,capture_output=True,check=True)
        r=subprocess.run(command+['bundle','restore',str(self.bundle)],env=self.env,capture_output=True,text=True,timeout=60)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(json.loads(r.stdout)['config_applied'])
        r=subprocess.run(command+['bundle','check',str(self.bundle)],env=self.env,capture_output=True,text=True,timeout=60)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(self.run_cli('bundle','restore',str(self.bundle)).returncode,1)

    def test_tampered_bundle_rejected_before_existing_data_changes(self):
        self.pack();(self.bundle/'recipe.env').write_text('NET=open\n')
        self.assertNotEqual(self.run_cli('bundle','verify',str(self.bundle)).returncode,0)
        self.assertTrue((self.ws/'.capbox/os/alpine/bin/sh').is_symlink())

    def test_bundle_paths_and_source_overlay_are_not_silently_accepted(self):
        r=self.run_cli('bundle','pack',str(self.ws/'export'))
        self.assertNotEqual(r.returncode,0)
        upper=self.ws/'.capbox/run/overlay/active/upper';upper.mkdir(parents=True)
        (upper/'file').write_text('state')
        self.assertNotEqual(self.run_cli('bundle','pack',str(self.bundle)).returncode,0)

    def test_archive_path_escape_is_rejected_even_with_a_matching_digest(self):
        self.pack()
        with tarfile.open(self.bundle/'rootfs.tar.gz','w:gz') as archive:
            info=tarfile.TarInfo('../outside');info.size=3;archive.addfile(info,io.BytesIO(b'bad'))
        manifest=json.loads((self.bundle/'manifest.json').read_text())
        manifest['files']['rootfs.tar.gz']=hashlib.sha256((self.bundle/'rootfs.tar.gz').read_bytes()).hexdigest()
        (self.bundle/'manifest.json').write_text(json.dumps(manifest))
        self.assertNotEqual(self.run_cli('bundle','verify',str(self.bundle)).returncode,0)
        self.assertFalse((self.base/'outside').exists())

    def test_recipe_requirements_must_match_the_locked_inventory(self):
        recipe=self.ws/'bundle.recipe'
        recipe.write_text('DISTRO=alpine\nPACKAGES=capbox-fixture-missing-package\n')
        r=self.run_cli('bundle','pack',str(self.bundle),'--recipe',str(recipe))
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.bundle.exists())


    def test_manifest_pin_and_architecture_are_checked(self):
        packed=self.pack()
        r=self.run_cli('bundle','verify',str(self.bundle),'--manifest-sha256',packed['manifest_sha256'])
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotEqual(self.run_cli('bundle','verify',str(self.bundle),'--manifest-sha256','0'*64).returncode,0)
        manifest=json.loads((self.bundle/'manifest.json').read_text())
        manifest['architecture']='unsupported-architecture'
        (self.bundle/'manifest.json').write_text(json.dumps(manifest))
        self.assertNotEqual(self.run_cli('bundle','verify',str(self.bundle)).returncode,0)


    def test_mcp_execution_and_log_readback(self):
        # The fixed shared mode avoids requiring a Git fixture; policy remains untrusted/none.
        self.env['CAPBOX_PROXY']='http://proxy-user:fixture-proxy-secret@127.0.0.1:9'
        proc=subprocess.Popen(self.cli+['mcp','serve','--workspace-mode','shared'],env=self.env,
                              stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        def send(message,response=True):
            proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush()
            return json.loads(proc.stdout.readline()) if response else None
        task=None
        try:
            send(initialization()[0]);send(initialization()[1],False)
            started=send(request(2,'tools/call',{'name':'capbox_execute','arguments':{'argv':['sh','-c','test -z "${http_proxy:-}" && printf mcp-ok'],'timeout':10}}))
            self.assertFalse(started['result']['isError'],started)
            task=started['result']['structuredContent']['task_id']
            self.run_cli('task','wait',task,'--timeout','15',check=True)
            logs=send(request(3,'tools/call',{'name':'capbox_logs','arguments':{'task_id':task}}))
            self.assertEqual(logs['result']['content'][0]['text'],'mcp-ok')
            self.assertEqual(logs['result']['structuredContent']['next_offset'],6)
        finally:
            proc.stdin.close();proc.wait(timeout=10);proc.stdout.close();proc.stderr.close()
            if task:self.run_cli('task','cancel',task);self.run_cli('task','rm',task)


    def test_default_mcp_entry_runs_bounded_guest_task(self):
        """P0 cut 3: bare mcp serve (isolated/untrusted/none) runs a trivial agent task end-to-end."""
        (self.ws/'probe.txt').write_text('host-side\n')
        proc=subprocess.Popen(self.cli+['mcp','serve'],env=self.env,
                              stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        def send(message,response=True):
            proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush()
            return json.loads(proc.stdout.readline()) if response else None
        task=None
        try:
            send(initialization()[0]);send(initialization()[1],False)
            policy=send(request(2,'tools/call',{'name':'capbox_policy','arguments':{}}))
            mcp=policy['result']['structuredContent']['mcp']
            self.assertEqual(mcp['workspace_mode'],'isolated')
            self.assertEqual(mcp['profile'],'untrusted')
            self.assertEqual(mcp['net'],'none')
            self.assertTrue(mcp['tools_cannot_raise_policy'])
            started=send(request(3,'tools/call',{'name':'capbox_execute','arguments':{
                'argv':['sh','-c','printf five-min-ok'],'timeout':15}}))
            self.assertFalse(started['result']['isError'],started)
            task=started['result']['structuredContent']['task_id']
            waited=self.run_cli('task','wait',task,'--timeout','20','--json')
            self.assertEqual(waited.returncode,0,waited.stdout+waited.stderr)
            self.assertEqual(json.loads(waited.stdout)['status'],'succeeded')
            status=send(request(4,'tools/call',{'name':'capbox_status','arguments':{'task_id':task}}))
            self.assertEqual(status['result']['structuredContent']['status'],'succeeded')
            logs=send(request(5,'tools/call',{'name':'capbox_logs','arguments':{'task_id':task}}))
            self.assertEqual(logs['result']['content'][0]['text'],'five-min-ok')
            # Isolated guest must not mutate the host tree for this trivial command.
            self.assertEqual((self.ws/'probe.txt').read_text(),'host-side\n')
        finally:
            proc.stdin.close();proc.wait(timeout=10);proc.stdout.close();proc.stderr.close()
            if task:self.run_cli('task','cancel',task);self.run_cli('task','rm',task)


if __name__=='__main__':unittest.main()

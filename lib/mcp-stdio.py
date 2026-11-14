#!/usr/bin/env python3
"""基于现有 task CLI 的按行 MCP 传输（有大小上限）。"""
import base64
import json
import sys
from pathlib import Path

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import i18n

_DEFAULTS = Path(__file__).with_name('mcp-defaults.py')
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location('capbox_mcp_defaults', _DEFAULTS)
_mod = _ilu.module_from_spec(_spec); _spec.loader.exec_module(_mod)
DEFAULT_PROFILE = _mod.DEFAULT_PROFILE
DEFAULT_NET = _mod.DEFAULT_NET
DEFAULT_WORKSPACE_MODE = _mod.DEFAULT_WORKSPACE_MODE
DEFAULT_MAX_TIMEOUT = _mod.DEFAULT_MAX_TIMEOUT
MAX_OUTPUT_BYTES = _mod.MAX_OUTPUT_BYTES

PROTOCOLS = ('2025-11-25', '2025-06-18')
MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 2 * 1024 * 1024


class ProtocolError(Exception):
    def __init__(self, message, code=-32602):
        super().__init__(message)
        self.code = code




def sanitize_cli_stderr(stderr_text):
    """保留 CapBox 错误行；去掉可能泄露宿主路径布局的绝对路径。"""
    if not stderr_text:
        return ''
    lines = []
    for line in stderr_text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('[capbox]') or line.startswith('[capbox MCP]'):
            cleaned = []
            for token in line.split(' '):
                cleaned.append('<path>' if token.startswith('/') and len(token) > 1 else token)
            lines.append(' '.join(cleaned))
    return ' | '.join(lines[:3])


def proc_stderr_text(proc):
    raw = getattr(proc, 'stderr', None)
    if raw is None:
        return ''
    if isinstance(raw, (bytes, bytearray)):
        return raw.decode('utf-8', 'replace')
    return str(raw)


def next_step_for_payload(name, data, returncode):
    """常见日常路径失败时的下一步提示（用户可见）。"""
    if not isinstance(data, dict):
        return None
    status = data.get('status')
    kind = data.get('kind')
    if kind == 'wait_timeout' or data.get('type') == 'wait_timeout':
        return i18n.t('mcp.hint_client_wait_timeout')
    if status == 'timed_out':
        return i18n.t('mcp.hint_execution_timeout')
    if name == 'capbox_logs' and not returncode and data.get('cursor_past_eof'):
        return i18n.t('mcp.hint_log_cursor_past_eof', offset=data.get('offset'), size=data.get('size', 0))
    if name == 'capbox_diff' and returncode:
        return i18n.t('mcp.hint_diff_failed')
    if returncode and name == 'capbox_execute':
        return i18n.t('mcp.hint_execute_failed')
    return None


def tool_error_text(name, proc, data=None):
    """组装失败文案：结构化下一步提示 + 净化后的 CLI stderr。"""
    hint = next_step_for_payload(name, data or {}, proc.returncode)
    stderr_bit = sanitize_cli_stderr(proc_stderr_text(proc))
    parts = []
    if hint:
        parts.append(hint)
    if stderr_bit:
        parts.append(stderr_bit)
    if not parts:
        parts.append(
            i18n.t('mcp.command_failed', code=proc.returncode))
    return ' '.join(parts)

def obj(properties=None, required=()):
    return {'type':'object','properties':properties or {},'required':list(required),'additionalProperties':False}


def tools(maximum):
    task={'type':'string','pattern':'^[0-9a-f]{32}$'}
    integer=lambda maximum: {'type':'integer','minimum':0,'maximum':maximum}
    specs=[
        ('capbox_execute',i18n.t('mcp.tool_execute_desc'),
         obj({'argv':{'type':'array','items':{'type':'string'},'minItems':1,'maxItems':256},
              'workspace_readonly':{'type':'boolean'},
              'write_dirs':{'type':'array','items':{'type':'string'},'minItems':0,'maxItems':256},
              'cwd':{'type':'string'},'timeout':{'type':'integer','minimum':1,'maximum':maximum}},['argv']),False),
        ('capbox_status',i18n.t('mcp.tool_status_desc'),obj({'task_id':task},['task_id']),True),
        ('capbox_logs',i18n.t('mcp.tool_logs_desc'),
         obj({'task_id':task,'stream':{'type':'string','enum':['stdout','stderr']},
              'offset':integer(64*1024*1024),'limit':integer(65536)},['task_id']),True),
        ('capbox_cancel',i18n.t('mcp.tool_cancel_desc'),obj({'task_id':task},['task_id']),False),
        ('capbox_diff',i18n.t('mcp.tool_diff_desc'),obj({'task_id':task},['task_id']),True),
        ('capbox_policy',i18n.t('mcp.tool_policy_desc'),obj(),True),
    ]
    return [{'name':name,'description':description,'inputSchema':schema,
             'annotations':{'readOnlyHint':readonly,'destructiveHint':name=='capbox_cancel',
                            'idempotentHint':readonly,'openWorldHint':not readonly}}
            for name,description,schema,readonly in specs]


def validate(schema, value):
    if type(value) is not dict or set(value)-set(schema['properties']) or set(schema['required'])-set(value):
        raise ProtocolError(i18n.t('mcp.invalid_tool_arguments'))
    import re
    for key,item in value.items():
        spec=schema['properties'][key];kind=spec['type']
        if kind=='string':
            if not isinstance(item,str) or len(item)>65536 or '\0' in item:raise ProtocolError(i18n.t('mcp.invalid_string_argument'))
            if 'pattern' in spec and not re.fullmatch(spec['pattern'],item):raise ProtocolError(i18n.t('mcp.invalid_task_id'))
            if 'enum' in spec and item not in spec['enum']:raise ProtocolError(i18n.t('mcp.invalid_stream'))
        elif kind=='boolean':
            if type(item) is not bool:raise ProtocolError(i18n.t('mcp.invalid_tool_arguments'))
        elif kind=='integer':
            if type(item) is not int or not spec['minimum']<=item<=spec['maximum']:raise ProtocolError(i18n.t('mcp.invalid_integer_argument'))
        elif kind=='array':
            if type(item) is not list or not spec['minItems']<=len(item)<=spec['maxItems']:raise ProtocolError(i18n.t('mcp.invalid_argv'))
            if any(not isinstance(s,str) or '\0' in s for s in item) or sum(len(s.encode()) for s in item)>65536:
                raise ProtocolError(i18n.t('mcp.invalid_argv_values'))


class Server:
    def __init__(self,ctx,args,invoke):
        self.ctx,self.args,self.invoke=ctx,args,invoke
        self.initialized=False;self.ready=False
        self.specs=tools(args.max_timeout)

    def call(self,name,arguments):
        spec=next((t for t in self.specs if t['name']==name),None)
        if spec is None:raise ProtocolError(i18n.t('mcp.unknown_tool'))
        validate(spec['inputSchema'],arguments)
        if name=='capbox_execute':
            cwd=arguments.get('cwd','/workspace')
            if not (cwd=='/workspace' or cwd.startswith('/workspace/')) or '..' in cwd.split('/'):
                raise ProtocolError(i18n.t('mcp.cwd_must_be_under_workspace'))
            command=['task','start','--timeout',str(arguments.get('timeout',self.args.max_timeout)),
                     '--cwd',cwd,'--profile',self.args.profile,'--net',self.args.net,
                     '--max-output-bytes',str(MAX_OUTPUT_BYTES)]
            if self.args.workspace_mode=='isolated':command+=['--isolate']
            if arguments.get('workspace_readonly'):command+=['--workspace-readonly']
            command+=['--write-dir='+path for path in arguments.get('write_dirs', [])]
            # env + -- 即使只有单个字符串参数也保持 argv 语义。
            command+=['--','env','--',*arguments['argv']]
        elif name=='capbox_policy':command=['policy','show','--profile',self.args.profile,'--net',self.args.net]
        else:
            action={'capbox_status':'status','capbox_logs':'logs','capbox_cancel':'cancel','capbox_diff':'diff'}[name]
            command=['task',action,arguments['task_id'],'--json']
            if name=='capbox_logs':
                command+=['--stream',arguments.get('stream','stdout'),'--offset',str(arguments.get('offset',0)),
                          '--limit',str(arguments.get('limit',65536))]
        proc=self.invoke(command)
        stdout=proc.stdout if isinstance(proc.stdout,str) else (proc.stdout or b'').decode('utf-8','replace')
        if len(stdout.encode('utf-8','replace'))>MAX_RESPONSE:
            return {'content':[{'type':'text','text':i18n.t('mcp.result_exceeds_size_limit')}],'isError':True}
        try:data=json.loads(stdout)
        except (ValueError,UnicodeError):
            # 不回显原始 argv / 宿主路径；只给出净化后的 CapBox 错误与下一步。
            return {'content':[{'type':'text','text':tool_error_text(name,proc)}],'isError':True}
        if name=='capbox_policy' and isinstance(data,dict) and not proc.returncode:
            data=dict(data)
            data['mcp']={
                'workspace_mode':self.args.workspace_mode,
                'profile':self.args.profile,
                'net':self.args.net,
                'max_timeout':self.args.max_timeout,
                'max_output_bytes':MAX_OUTPUT_BYTES,
                'tools_cannot_raise_policy':True,
            }
            if self.args.net=='restricted':
                data['mcp']['credential_note']=i18n.t('mcp.credential_note_restricted')
        body=json.dumps(data,ensure_ascii=True)
        if name=='capbox_logs' and not proc.returncode:
            body=base64.b64decode(data['data_base64']).decode('utf-8','replace')
            hint=next_step_for_payload(name,data,proc.returncode)
            if hint and not body:
                body=hint
        elif proc.returncode or (isinstance(data,dict) and data.get('status')=='timed_out'):
            hint=next_step_for_payload(name,data,proc.returncode)
            if hint:
                # 结构化 JSON 仍可用；文本通道以下一步提示开头。
                body=hint+'\n'+body if name!='capbox_logs' else hint
            elif proc.returncode:
                extra=tool_error_text(name,proc,data)
                body=extra+'\n'+body
        return {'content':[{'type':'text','text':body}],'structuredContent':data,'isError':proc.returncode!=0}

    def dispatch(self,message):
        if not isinstance(message,dict) or message.get('jsonrpc')!='2.0' or not isinstance(message.get('method'),str):
            raise ProtocolError(i18n.t('mcp.invalid_request'),-32600)
        has_id='id' in message
        if has_id and (type(message['id']) not in (str,int) or isinstance(message['id'],bool)):
            raise ProtocolError(i18n.t('mcp.invalid_request_id'),-32600)
        method=message['method'];params=message.get('params',{})
        if not isinstance(params,dict):raise ProtocolError(i18n.t('mcp.invalid_params'))
        if not has_id:
            if method=='notifications/initialized' and self.initialized:self.ready=True
            return None
        if method=='ping':return {}
        if method=='initialize':
            if self.initialized:raise ProtocolError(i18n.t('mcp.already_initialized'),-32600)
            if (not isinstance(params.get('protocolVersion'),str) or not isinstance(params.get('capabilities'),dict)
                or not isinstance(params.get('clientInfo'),dict)
                or not all(isinstance(params['clientInfo'].get(k),str) for k in ('name','version'))):
                raise ProtocolError(i18n.t('mcp.invalid_initialize_params'))
            self.initialized=True
            protocol=params['protocolVersion'] if params['protocolVersion'] in PROTOCOLS else PROTOCOLS[0]
            return {'protocolVersion':protocol,'capabilities':{'tools':{'listChanged':False}},
                    'serverInfo':{'name':'capbox','version':self.ctx['version']},
                    'instructions':i18n.t('mcp.instructions')}
        if not self.ready:raise ProtocolError(i18n.t('mcp.need_initialize_first'),-32000)
        if method=='tools/list':
            if params.get('cursor') is not None:raise ProtocolError(i18n.t('mcp.invalid_tools_list_cursor'))
            return {'tools':self.specs}
        if method=='tools/call':
            if not isinstance(params.get('name'),str):raise ProtocolError(i18n.t('mcp.missing_tool_name'))
            return self.call(params['name'],params.get('arguments',{}))
        raise ProtocolError(i18n.t('mcp.method_not_found'),-32601)


def bounded_integer(value):
    if len(value)>20:raise ValueError(i18n.t('mcp.integer_too_large'))
    return int(value)


def invalid_constant(value):
    raise ValueError(i18n.t('mcp.not_a_json_number_constant'))


def unique_pairs(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError(i18n.t('mcp.json_duplicate_key'))
        result[key]=value
    return result


def serve(ctx,args,invoke):
    if not 1<=args.max_timeout<=3600:raise ValueError(i18n.t('mcp.max_timeout_range'))
    if args.net=='restricted' and not ctx['config']['NET_ALLOW']:
        raise ValueError(i18n.t('mcp.restricted_requires_net_allow'))
    server=Server(ctx,args,invoke)
    incoming=sys.stdin.buffer
    while True:
        raw=incoming.readline(MAX_REQUEST+1)
        if not raw:break
        request_id=None;notification=False
        try:
            if len(raw)>MAX_REQUEST:
                while raw and not raw.endswith(b'\n'):raw=incoming.readline(MAX_REQUEST+1)
                raise ProtocolError(i18n.t('mcp.message_too_large'),-32700)
            try:message=json.loads(raw.decode("utf-8"),object_pairs_hook=unique_pairs,parse_int=bounded_integer,parse_constant=invalid_constant)
            except (ValueError,UnicodeError,RecursionError):raise ProtocolError(i18n.t('mcp.parse_error'),-32700)
            if isinstance(message,dict):
                candidate=message.get('id')
                request_id=candidate if type(candidate) in (str,int) else None
                notification=message.get('jsonrpc')=='2.0' and 'id' not in message and isinstance(message.get('method'),str)
            result=server.dispatch(message)
            if result is None:continue
            response={'jsonrpc':'2.0','id':request_id,'result':result}
        except ProtocolError as exc:
            if notification:continue
            response={'jsonrpc':'2.0','id':request_id,'error':{'code':exc.code,'message':str(exc)}}
        except (OSError,ValueError,KeyError,TypeError) as exc:
            response={'jsonrpc':'2.0','id':request_id,'error':{'code':-32603,'message':i18n.t('mcp.internal_tool_error')}}
            print('[capbox MCP] '+type(exc).__name__,file=sys.stderr)
        except Exception as exc:
            response={'jsonrpc':'2.0','id':request_id,'error':{'code':-32603,'message':i18n.t('mcp.tool_call_failed')}}
            print('[capbox MCP] '+type(exc).__name__,file=sys.stderr)
        print(json.dumps(response,ensure_ascii=True,separators=(',',':')),flush=True)
    return 0

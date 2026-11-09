#!/usr/bin/env python3
"""The public report CLI must bound, escape and preserve its audit source."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import unittest
from test_agent_workflows import Fixture


def event(index=0, **values):
    return dict(ts='2026-11-08T%02d:00:00Z' % index, kind='exec', status='ok', ms=100+index, **values)


class AuditReportTests(Fixture):
    def setUp(self):
        super().setUp()
        self.source = self.ws/'.capbox/logs/audit.jsonl'
        self.output = self.base/'report.html'

    def records(self, *values):
        self.source.write_text(''.join(json.dumps(value)+'\n' for value in values))

    def generate(self, *args, check=True):
        return self.run_cli('audit','report','--output',str(self.output),'--json',*map(str,args),check=check)

    def data(self):
        html = self.output.read_text()
        match = re.search(r'<script id="report-data" type="application/json">(.*?)</script>',html,re.S)
        return json.loads(match[1])

    def test_snapshot_and_template_are_self_contained_with_hash_csp(self):
        self.records(event(0,cmd='echo (+1 args)'),event(1))
        result = json.loads(self.generate().stdout)
        self.assertEqual(result['events'],2)
        self.assertEqual(self.data()['schema'],'capbox.audit-report.v1')
        html=self.output.read_text()
        for tag in ('style','script'):
            code=re.search(r'<'+tag+r' data-app>(.*?)</'+tag+'>',html,re.S)[1]
            digest=base64.b64encode(hashlib.sha256(code.encode()).digest()).decode()
            self.assertIn("'sha256-"+digest+"'",html)
        self.assertIn("connect-src 'none'",html)
        self.assertNotRegex(html,r'<(?:script|link)[^>]+(?:src|href)=[\"\x27]https?://')
        self.assertNotIn(str(self.ws),html)
        self.assertEqual(self.output.stat().st_mode&0o777,0o600)

    def test_filters_are_utc_inclusive_since_exclusive_until_and_latest_in_file(self):
        values=[event(i) for i in range(5)]
        values[3]['status']='fail';values[3]['exit']=7
        self.records(*values)
        self.generate('--since','2026-11-08T01:00:00Z','--until','2026-11-08T04:00:00Z',
                      '--kind','exec','--status','ok','--limit','1')
        data=self.data()
        self.assertEqual([e['ts'] for e in data['events']],['2026-11-08T02:00:00.000Z'])
        self.assertEqual(data['coverage']['matching_records'],2)
        self.assertEqual(data['coverage']['omitted_records'],1)

    def test_limit_means_file_order_even_when_timestamps_arrive_out_of_order(self):
        self.records(event(5),event(1),event(3))
        self.generate('--limit','2')
        self.assertEqual([e['ts'][11:13] for e in self.data()['events']],['01','03'])

    def test_known_secrets_are_redacted_and_html_payload_is_inert(self):
        payload='</script><img src=x onerror="globalThis.auditInjected=1"><script>alert(1)</script>'
        self.records(event(0,cmd='GITHUB_TOKEN=environment-fixture-secret OPENAI_API_KEY=api-fixture-secret '
                           'AWS_SECRET_ACCESS_KEY=cloud-fixture-secret curl --token command-fixture-secret '
                           'https://user:proxy-fixture-secret@example.com/',
                           detail='password="quoted fixture secret" Authorization: Bearer bearer-fixture-secret',
                           object=payload))
        self.generate()
        html=self.output.read_text()
        for secret in ('command-fixture-secret','proxy-fixture-secret','quoted fixture secret','bearer-fixture-secret',
                       'environment-fixture-secret','api-fixture-secret','cloud-fixture-secret'):
            self.assertNotIn(secret,html)
        self.assertNotIn(payload,html)
        self.assertEqual(self.data()['events'][0]['object'],payload)
        self.assertGreaterEqual(self.data()['coverage']['redacted_fields'],2)

    def test_bad_json_duplicate_keys_constants_and_incomplete_tail_are_reported(self):
        self.source.write_bytes((json.dumps(event())+'\n').encode()+
            b'{not-json}\n'+b'{"ts":"x","ts":"y"}\n'+b'{"ms":NaN}\n'+b'\xff\n'+
            b'{"id":'+b'9'*100+b'}\n'+b'{"unfinished":')
        self.generate()
        coverage=self.data()['coverage']
        self.assertEqual(coverage['valid_records'],1)
        self.assertEqual(coverage['invalid_records'],5)
        self.assertEqual(coverage['incomplete_records'],1)

    def test_large_lines_and_fields_are_bounded_and_invalid_optional_values_omitted(self):
        value=event(detail='x'*3000);value['ms']=True;value['exit']='bad'
        self.source.write_text('x'*(64*1024+1)+'\n'+json.dumps(value)+'\n')
        self.generate()
        data=self.data()
        self.assertEqual(data['coverage']['oversized_records'],1)
        self.assertEqual(data['coverage']['invalid_fields'],2)
        self.assertEqual(data['coverage']['truncated_fields'],1)
        self.assertNotIn('ms',data['events'][0]);self.assertNotIn('exit',data['events'][0])
        self.assertLess(len(data['events'][0]['detail']),2100)

    def test_missing_default_audit_is_an_honest_empty_report(self):
        self.generate()
        self.assertEqual(self.data()['events'],[])
        self.assertTrue(self.data()['coverage']['source_missing'])
        self.assertFalse(self.source.exists())

    def test_explicit_missing_input_and_invalid_ranges_do_not_publish(self):
        for args in (('--input',self.base/'missing'),('--limit','0'),('--limit','20001'),
                     ('--since','2026-11-09','--until','2026-11-08'),
                     ('--since','2026-11-08T10:00:00')):
            self.assertNotEqual(self.generate(*args,check=False).returncode,0)
            self.assertFalse(self.output.exists())

    def test_guest_visible_output_is_refused(self):
        target=self.ws/'report.html'
        r=self.run_cli('audit','report','--output',str(target))
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(target.exists())

    def test_source_links_ancestor_links_and_special_files_are_refused(self):
        outside=self.base/'outside.jsonl';outside.write_text(json.dumps(event())+'\n')
        self.source.symlink_to(outside)
        self.assertNotEqual(self.generate(check=False).returncode,0)
        self.source.unlink();os.mkfifo(self.source)
        self.assertNotEqual(self.generate(check=False).returncode,0)
        self.source.unlink()
        alias=self.base/'alias';alias.symlink_to(self.ws/'.capbox/logs',target_is_directory=True)
        self.source.write_text(json.dumps(event())+'\n')
        self.assertNotEqual(self.generate('--input',alias/'audit.jsonl',check=False).returncode,0)
        self.assertFalse(self.output.exists())

    def test_existing_output_needs_force_and_symlinks_are_never_replaced(self):
        self.output.write_text('keep')
        self.assertNotEqual(self.generate(check=False).returncode,0)
        self.assertEqual(self.output.read_text(),'keep')
        self.generate('--force')
        self.assertEqual(self.output.stat().st_mode&0o777,0o600)
        self.output.unlink()
        victim=self.base/'victim';victim.write_text('keep')
        self.output.symlink_to(victim)
        self.assertNotEqual(self.generate('--force',check=False).returncode,0)
        self.assertEqual(victim.read_text(),'keep')

    def test_output_cannot_replace_an_explicit_source_or_its_hardlink(self):
        self.output.write_text(json.dumps(event())+'\n');before=self.output.read_bytes()
        self.assertNotEqual(self.generate('--input',self.output,'--force',check=False).returncode,0)
        self.assertEqual(self.output.read_bytes(),before)
        alias=self.base/'linked';os.link(self.output,alias)
        self.assertNotEqual(self.generate('--input',alias,'--force',check=False).returncode,0)
        self.assertEqual(self.output.read_bytes(),before)

    def test_large_source_only_scans_the_bounded_tail(self):
        with self.source.open('wb') as f:
            f.write((json.dumps(event(0,cmd='old-source-marker'))+'\n').encode())
            f.seek(33*1024*1024)
            f.write(b'\n'+(json.dumps(event(2,cmd='recent-event'))+'\n').encode())
        self.generate()
        data=self.data()
        self.assertLessEqual(data['coverage']['scanned_bytes'],32*1024*1024)
        self.assertGreater(data['coverage']['omitted_prefix_bytes'],0)
        self.assertEqual([e['cmd'] for e in data['events']],['recent-event'])

    def test_bootstrap_installs_both_renderer_and_template(self):
        self.assertTrue((self.ws/'.capbox/lib/audit-report.py').is_file())
        self.assertTrue((self.ws/'.capbox/lib/audit-report.html').is_file())
        self.records(event())
        local=self.ws/'.capbox/bin/capbox'
        import subprocess
        r=subprocess.run([str(local),'--root',str(self.ws),'audit','report','--output',str(self.output)],
                         env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('已生成审计报告',r.stdout)


if __name__=='__main__':unittest.main(verbosity=2)

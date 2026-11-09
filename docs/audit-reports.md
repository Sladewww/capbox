# Offline audit reports

Requires host Python 3.10+. No server, frontend installation or network connection is needed to generate or view the report.

```sh
mkdir -p "$HOME/capbox-reports"
capbox audit report --output "$HOME/capbox-reports/audit.html"
# Explicitly regenerate an existing ordinary report:
capbox audit report --output "$HOME/capbox-reports/audit.html" --force
```

Open the HTML in a browser. Data, styles and scripts are embedded. Search, UTC date/type/status filters, sorting, pagination, event details and filtered JSON export run locally. The trend, type breakdown and cards update together. Escape closes details; controls also work on narrow screens. Printing includes the current table page.

## Choose what to export

```sh
capbox audit report --output /path/outside/project/failures.html \
  --since 2026-11-08 --until 2026-11-09 \
  --kind exec --status fail --limit 5000 --json
capbox audit report --input /path/to/archived-audit.jsonl \
  --output /path/outside/project/archive.html
```

`--since` is inclusive and `--until` exclusive. A date means midnight UTC; datetimes require a timezone, such as `2026-11-08T10:00:00+08:00`. Repeat `--kind` or `--status` for several allowed values. The browser's end-date filter includes that entire UTC day. `--json` prints generation metadata, coverage and the output path.

The default source is the project's `logs/audit.jsonl`. A missing default source produces an explicitly empty report; an explicit missing `--input` fails. Reports do not enable collection, execute logged commands, collect new telemetry or change the source. Existing `AUDIT` and `AUDIT_CMD` settings still control collection.

Only the selected JSONL is included. Other projects, rotated files and private isolated-task copies are not automatically aggregated. Event count is not task count: one execution can emit several policy/resource/exec records. Reports do not add task correlation IDs or claim that unrecorded events succeeded.

## Coverage and statistics

- Scan at most the final **32MiB** of the source's initial file size. Discard any first partial record. Concurrent appends are not chased indefinitely.
- Keep the last **5,000 matching records in file order** by default; `--limit` accepts 1–20,000. Display order uses timestamps. Out-of-order timestamps do not change which records survive retention.
- Lines over **64KiB**, invalid JSON/UTF-8, duplicate keys, invalid required fields and non-JSON constants are skipped. An incomplete trailing line is skipped and reported. Records need `ts`, `kind`, `status` and a timezone-aware timestamp.
- Known text fields are capped at **2,048 characters** after redaction. Invalid optional numbers are omitted and counted. Unknown fields are not embedded. Embedded JSON is limited to **32MiB**; reduce the record/time limit if exceeded.
- Failure means `status=fail` or a nonzero recorded exit code; warnings use `status=warn`. Start/stop/skip do not automatically mean success. Nearest-rank P95 uses **exec records with valid `ms` only**; missing durations remain missing.

Coverage records source/scan sizes, discarded prefix, omitted matching records, malformed/oversized/incomplete records and invalid/truncated/redacted fields. These counts describe the scan window; visible statistics describe retained, currently filtered events. A report is a bounded observation, not a completeness or authenticity proof.

## Files and sensitive data

Output must be **outside the workspace**, with an existing parent directory. It is created privately with mode `0600`. Existing files require `--force`; symlinks, special output files and an output aliasing the input are refused. Source paths and ancestors must not be symlinks; the source must be a regular file. Publication is atomic, with no replacement by default.

Embedded JSON is escaped and event content uses text-only DOM operations. A hash-based Content Security Policy permits only the report's own script/style and disallows connections/external resources. HTML-looking log text is displayed as data.

Common credential assignments/flags, Bearer/Basic values and HTTP URL userinfo receive additional best-effort redaction. This cannot recognise all secrets or confidential paths. **HTML contains retained data even when a browser filter hides it.** JSON export contains only current matches; the original HTML is unchanged. Review before sharing. A local report is not an upload or signed audit archive.

## Development checks

```sh
python3 test/security/test_audit_report.py
npm ci --prefix test/browser --ignore-scripts --no-audit --no-fund
test/browser/node_modules/.bin/playwright install chromium
npm --prefix test/browser test
```

The pinned browser dependency is for tests only. Chromium opens the actual `file://` report and exercises filters/details/pagination/downloads/mobile layout, inert hostile text, CSP and zero network requests. Users do not need a browser package installation beyond their normal browser.

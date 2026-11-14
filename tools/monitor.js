"use strict";

const get = id => document.getElementById(id);
const clock = new Intl.DateTimeFormat("zh-CN", {dateStyle: "short", timeStyle: "medium"});
function time(seconds) {
  const date = new Date(seconds * 1000);
  return seconds == null || !Number.isFinite(date.getTime()) ? "—" : clock.format(date);
}
const size = bytes => bytes == null ? "—" : `${(bytes / 1048576).toFixed(1)} MiB`;
const labels = {
  running: "运行中", stopped: "已停止", preparing: "准备中", succeeded: "成功",
  failed: "失败", cancelled: "已取消", timed_out: "超时", lost: "任务失联",
  unavailable: "采集失败", ok: "成功", ready: "可用", denied: "权限不足",
  missing: "不可用", unset: "未配置", warn: "告警", require: "要求生效",
  capable: "可用", unsupported: "不支持"
};
const label = status => labels[status] ?? status;
let snapshot = {};
let hasSnapshot = false;
const renderedTables = new Map();
let connected = false;

function element(tag, text) {
  const node = document.createElement(tag);
  node.textContent = text ?? "—";
  return node;
}

function details(id, entries) {
  get(id).replaceChildren(...entries.flatMap(([name, value]) =>
    [element("dt", name), element("dd", value)]));
}

function table(id, rows, columns, message) {
  const signature = JSON.stringify([rows, message]);
  if (renderedTables.get(id) === signature) return;
  renderedTables.set(id, signature);
  const rendered = rows.map(values => {
    const row = document.createElement("tr");
    row.append(...values.map(value => element("td", value)));
    return row;
  });
  if (!rendered.length) {
    const cell = element("td", message);
    cell.colSpan = columns;
    const row = document.createElement("tr");
    row.append(cell);
    rendered.push(row);
  }
  get(id).replaceChildren(...rendered);
}

function render() {
  const overview = snapshot.overview?.data ?? {};
  const daemon = overview.daemon;
  details("overview", [
    ["Daemon", daemon ? label(daemon.running ? "running" : "stopped") : null],
    ["运行时间", daemon?.running ? `${daemon.uptime} 秒` : null],
    ["发行版", overview.distro], ["网络模式", overview.net],
    ["Rootfs", size(overview.rootfs_bytes)], ["CapBox 版本", overview.version]
  ]);
  const resources = snapshot.resources?.data ?? {};
  details("resources", [
    ["Cgroup", label(resources.cgroup_status)], ["磁盘支持", label(resources.disk_status)],
    ["执行模式", label(resources.mode)], ["CPU 限制", resources.cpu_max || "未配置"],
    ["内存限制", resources.memory_max || "未配置"], ["PID 限制", resources.pids_max || "未配置"]
  ]);
  const usage = snapshot.usage?.data;
  details("usage", [
    ["CPU", usage?.cpu_percent == null ? null : `${usage.cpu_percent}%`],
    ["内存", size(usage?.memory_bytes)], ["PID 数", usage?.pids]
  ]);
  const empty = (id, message) => snapshot[id]?.error ? "采集失败" : snapshot[id] ? message : "等待采样";
  table("services", (snapshot.services?.data ?? []).map(row => [row.name, label(row.state)]),
    2, empty("services", "暂无已配置的服务"));
  table("tasks", (snapshot.tasks?.data ?? []).map(row =>
    [row.task_id, label(row.status), time(row.created_at), row.exit_code]),
    4, empty("tasks", "暂无任务"));
  table("audit", (snapshot.audit?.data ?? []).map(row =>
    [row.ts, row.kind ?? row.event, label(row.status), row.exit, row.ms == null ? null : `${row.ms} ms`]),
    5, empty("audit", "暂无审计事件"));
  renderStatus();
}

function renderStatus() {
  const now = Date.now() / 1000;
  const connection = get("connection");
  connection.textContent = connected ? "实时连接" : hasSnapshot ? "连接中断，正在重连" : "正在连接";
  connection.dataset.tone = connected ? "ok" : "warn";
  for (const id of ["overview", "resources", "usage", "services", "tasks", "audit"]) {
    const record = snapshot[id];
    const target = get(`${id}-time`);
    const deadline = id === "overview" || id === "resources" ? 35 : 10;
    const stale = record?.sampled_at != null && now - record.sampled_at > deadline;
    let status = "等待采样";
    if (record?.error) status = "采集失败";
    else if (stale) status = "数据已过期";
    else if (record && id === "usage" && record.data == null) status = "不可用 · 未指定 cgroup";
    else if (record) status = "已采样";
    target.dataset.tone = record?.error ? "error" : stale ? "warn" : "";
    target.textContent = record?.sampled_at == null ? status : `${status} · ${time(record.sampled_at)}`;
  }
}

const events = new EventSource("/events");
events.onmessage = event => {
  snapshot = JSON.parse(event.data);
  connected = true;
  hasSnapshot = true;
  render();
};
events.onerror = () => {
  connected = false;
  renderStatus();
};
render();
setInterval(renderStatus, 1000);

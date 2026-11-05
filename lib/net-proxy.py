#!/usr/bin/env python3
# CapBox host-side allowlist HTTP proxy + guest-netns TCP↔UNIX bridge.
# Never executed inside untrusted recipe files; CapBox launches it explicitly.
from __future__ import annotations

import argparse
import ipaddress
import os
import select
import socket
import sys
import threading
from typing import Iterable, List, Optional, Tuple

BUF = 65536
BRIDGE_PORT_DEFAULT = 18787


def _norm_host(h: str) -> str:
    h = (h or "").strip().lower().rstrip(".")
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    return h


def parse_allowlist(raw: str) -> List[str]:
    out: List[str] = []
    for part in (raw or "").split(","):
        p = _norm_host(part)
        if p:
            out.append(p)
    return out


def host_allowed(host: str, allow: Iterable[str]) -> bool:
    host = _norm_host(host)
    if not host:
        return False
    # strip optional port from host:port (not for IPv6 without brackets — CONNECT uses host:port)
    if host.count(":") == 1 and not host.startswith("["):
        maybe_host, maybe_port = host.rsplit(":", 1)
        if maybe_port.isdigit():
            host = maybe_host
    try:
        ip = ipaddress.ip_address(host)
        for a in allow:
            try:
                if ip == ipaddress.ip_address(a):
                    return True
                if "/" in a and ip in ipaddress.ip_network(a, strict=False):
                    return True
            except ValueError:
                continue
        return False
    except ValueError:
        pass
    for a in allow:
        if not a or "/" in a:
            continue
        try:
            ipaddress.ip_address(a)
            continue
        except ValueError:
            pass
        # 域名规则至少含一个点，避免把 "com" 当成后缀放行 evil.com
        if "." not in a:
            continue
        if host == a or host.endswith("." + a):
            return True
    return False


def _split_hostport(authority: str, default_port: int) -> Tuple[str, int]:
    authority = authority.strip()
    if authority.startswith("["):
        # [ipv6]:port
        end = authority.find("]")
        if end < 0:
            return _norm_host(authority), default_port
        host = authority[1:end]
        rest = authority[end + 1 :]
        if rest.startswith(":") and rest[1:].isdigit():
            return _norm_host(host), int(rest[1:])
        return _norm_host(host), default_port
    if authority.count(":") == 1:
        h, p = authority.rsplit(":", 1)
        if p.isdigit():
            return _norm_host(h), int(p)
    return _norm_host(authority), default_port


def _relay(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                break
            for s in r:
                other = b if s is a else a
                data = s.recv(BUF)
                if not data:
                    return
                other.sendall(data)
    except OSError:
        return
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def _read_headers(conn: socket.socket) -> bytes:
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf



def handle_client(conn: socket.socket, allow: List[str], log: bool) -> None:
    try:
        head = _read_headers(conn)
        if not head:
            conn.close()
            return
        try:
            header_blob, body = head.split(b"\r\n\r\n", 1)
            header_text = header_blob.decode("iso-8859-1", "replace")
        except Exception:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        lines = header_text.split("\r\n")
        if not lines:
            conn.close()
            return
        parts = lines[0].split()
        if len(parts) < 2:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        method, target = parts[0].upper(), parts[1]
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        if method == "CONNECT":
            host, port = _split_hostport(target, 443)
            if not host_allowed(host, allow):
                if log:
                    print(f"capbox-net DENY CONNECT {host}:{port}", file=sys.stderr)
                conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                conn.close()
                return
            if log:
                print(f"capbox-net ALLOW CONNECT {host}:{port}", file=sys.stderr)
            try:
                upstream = socket.create_connection((host, port), timeout=20)
            except OSError:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                conn.close()
                return
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            _relay(conn, upstream)
            return

        host_hdr = headers.get("host", "")
        default_port = 80
        if target.startswith("https://"):
            default_port = 443
        if target.startswith("http://") or target.startswith("https://"):
            rest = target.split("://", 1)[1]
            if "/" in rest:
                auth, path = rest.split("/", 1)
                target_path = "/" + path
            else:
                auth, target_path = rest, "/"
            host, port = _split_hostport(auth, default_port)
        else:
            host, port = _split_hostport(host_hdr, default_port)
            target_path = target
        if not host:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        if not host_allowed(host, allow):
            if log:
                print(f"capbox-net DENY {method} {host}", file=sys.stderr)
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        if log:
            print(f"capbox-net ALLOW {method} {host}:{port}", file=sys.stderr)
        try:
            upstream = socket.create_connection((host, port), timeout=20)
        except OSError:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        skip = {"proxy-connection", "proxy-authorization", "connection", "keep-alive", "te", "transfer-encoding"}
        out_headers = []
        saw_host = False
        for line in lines[1:]:
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            kl = k.strip().lower()
            if kl in skip:
                continue
            if kl == "host":
                saw_host = True
                out_headers.append(f"Host: {host_hdr or host}")
            else:
                out_headers.append(f"{k.strip()}: {v.strip()}")
        if not saw_host:
            out_headers.insert(0, f"Host: {host_hdr or host}")
        out_headers.append("Connection: close")
        req_bytes = (
            f"{method} {target_path} HTTP/1.1\r\n".encode("ascii", "replace")
            + ("\r\n".join(out_headers) + "\r\n\r\n").encode("iso-8859-1", "replace")
            + body
        )
        upstream.sendall(req_bytes)
        _relay(conn, upstream)
    except Exception as exc:  # noqa: BLE001
        try:
            conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass
        if log:
            print(f"capbox-net error: {exc}", file=sys.stderr)


def cmd_proxy(args: argparse.Namespace) -> int:
    allow = parse_allowlist(args.allow)
    if not allow:
        print("capbox-net: allowlist empty", file=sys.stderr)
        return 2
    sock_path = args.sock
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    os.makedirs(os.path.dirname(sock_path) or ".", exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o600)
    server.listen(128)
    if args.ready:
        with open(args.ready, "w", encoding="utf-8") as fh:
            fh.write("ready\n")
    print(f"capbox-net proxy listening on unix:{sock_path} allow={','.join(allow)}", file=sys.stderr)
    try:
        while True:
            conn, _ = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, allow, args.log), daemon=True)
            t.start()
    except KeyboardInterrupt:
        return 0
    finally:
        try:
            server.close()
        except OSError:
            pass
        try:
            os.unlink(sock_path)
        except OSError:
            pass


def cmd_bridge(args: argparse.Namespace) -> int:
    # Listen on TCP in current netns; forward to UNIX sock (host mount ns).
    host, port_s = args.listen.split(":", 1)
    port = int(port_s)
    # Bring-up of lo is done by CapBox shell before invoking bridge.
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(128)
    if args.ready:
        with open(args.ready, "w", encoding="utf-8") as fh:
            fh.write("ready\n")
    print(f"capbox-net bridge {host}:{port} -> unix:{args.sock}", file=sys.stderr)

    def one(c: socket.socket) -> None:
        try:
            u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            u.connect(args.sock)
            _relay(c, u)
        except OSError:
            try:
                c.close()
            except OSError:
                pass

    try:
        while True:
            c, _ = server.accept()
            threading.Thread(target=one, args=(c,), daemon=True).start()
    except KeyboardInterrupt:
        return 0


def cmd_check_allow(args: argparse.Namespace) -> int:
    allow = parse_allowlist(args.allow)
    host = args.host
    ok = host_allowed(host, allow)
    print("allow" if ok else "deny")
    return 0 if ok else 1


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="capbox-net")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_proxy = sub.add_parser("proxy")
    p_proxy.add_argument("--sock", required=True)
    p_proxy.add_argument("--allow", required=True)
    p_proxy.add_argument("--ready")
    p_proxy.add_argument("--log", action="store_true")
    p_proxy.set_defaults(func=cmd_proxy)

    p_br = sub.add_parser("bridge")
    p_br.add_argument("--listen", default=f"127.0.0.1:{BRIDGE_PORT_DEFAULT}")
    p_br.add_argument("--sock", required=True)
    p_br.add_argument("--ready")
    p_br.set_defaults(func=cmd_bridge)

    p_ck = sub.add_parser("check-allow")
    p_ck.add_argument("--allow", required=True)
    p_ck.add_argument("--host", required=True)
    p_ck.set_defaults(func=cmd_check_allow)

    args = p.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())

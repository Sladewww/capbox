#!/usr/bin/env bash
# CapBox 慢速真实服务集成测试（默认不进 CI）
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLOW_ROOT="${CAPBOX_SLOW_ROOT:-}"
if [[ -z "$SLOW_ROOT" ]]; then
  if [[ -d /workspace/capbox-mssql-test/.capbox/os/ubuntu ]]; then
    SLOW_ROOT=/workspace/capbox-mssql-test
  else
    echo "请设置 CAPBOX_SLOW_ROOT" >&2; exit 2
  fi
fi
CB="$ROOT/bin/capbox"
CB_ROOT=(--root "$SLOW_ROOT")
echo "[slow] root=$SLOW_ROOT"
if [[ -d "$SLOW_ROOT/.capbox/lib" && "$ROOT/lib" != "$SLOW_ROOT/.capbox/lib" ]]; then
  cp -a "$ROOT/lib/." "$SLOW_ROOT/.capbox/lib/"
  cp -a "$ROOT/bin/capbox" "$SLOW_ROOT/.capbox/bin/capbox"
fi
run() { "$CB" "${CB_ROOT[@]}" "$@"; }
cleanup() {
  for s in slow-nginx slow-apache slow-redis slow-memcached slow-mariadb slow-sshd; do
    run service stop "$s" 2>/dev/null || true
  done
  for p in 18080 18081 16379 11212 13307 12222; do fuser -k "${p}/tcp" 2>/dev/null || true; done
}
trap cleanup EXIT
cleanup
SVC="$SLOW_ROOT/.capbox/services"
mkdir -p "$SVC" "$SLOW_ROOT/service-test/slow"
set +o noclobber 2>/dev/null || true
run config set CAPBOX_IDMAP auto >/dev/null || true
run doctor || true
pass=0; fail=0
ok() { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
write_env() { printf '%s\n' "$2" >"$SVC/$1.env"; }

if run exec -- test -x /usr/sbin/nginx; then
  mkdir -p "$SLOW_ROOT/service-test/slow/nginx/logs" "$SLOW_ROOT/service-test/slow/nginx/body"
  cat > "$SLOW_ROOT/service-test/slow/nginx.conf" <<'NG'
worker_processes 1;
error_log /workspace/service-test/slow/nginx/logs/error.log;
pid /workspace/service-test/slow/nginx/nginx.pid;
events { worker_connections 64; }
http {
  access_log /workspace/service-test/slow/nginx/logs/access.log;
  client_body_temp_path /workspace/service-test/slow/nginx/body;
  server {
    listen 127.0.0.1:18080;
    location / { default_type text/plain; return 200 'Nginx inside CapBox\n'; }
  }
}
NG
  write_env slow-nginx "CMD='nginx -c /workspace/service-test/slow/nginx.conf -g \"daemon off;\"'
CWD=/"
  if run service start slow-nginx; then
    sleep 0.5
    if curl -fsS http://127.0.0.1:18080/ | grep -q 'Nginx inside CapBox'; then ok "nginx HTTP 200"; else bad "nginx HTTP"; fi
    run service stop slow-nginx || true
  else bad "nginx start"; fi
else echo "  SKIP  nginx 未安装"; fi

if run exec -- test -x /usr/sbin/apache2 && [[ -f $SLOW_ROOT/service-test/apache2/httpd.conf ]]; then
  [[ -e $SLOW_ROOT/service-test/apache2/modules ]] || ln -sfn "$SLOW_ROOT/.capbox/os/ubuntu/usr/lib/apache2/modules" "$SLOW_ROOT/service-test/apache2/modules" 2>/dev/null || true
  write_env slow-apache "CMD='apache2 -f /workspace/service-test/apache2/httpd.conf -DFOREGROUND'
CWD=/"
  if run service start slow-apache; then
    sleep 0.6
    code=$(curl -fsS -o /tmp/apache-out -w '%{http_code}' http://127.0.0.1:18081/ || true)
    if [[ "$code" == "200" ]]; then ok "apache HTTP 200"; else bad "apache HTTP code=$code"; run service logs slow-apache -n 20 || true; fi
    run service stop slow-apache || true
  else bad "apache start"; run service logs slow-apache -n 20 || true; fi
else echo "  SKIP  apache 未安装或缺少 httpd.conf"; fi

if run exec -- sh -c 'command -v redis-server >/dev/null'; then
  write_env slow-redis "CMD='redis-server --port 16379 --bind 127.0.0.1 --protected-mode no --daemonize no --dir /tmp --dbfilename slow-redis.rdb'
CWD=/"
  if run service start slow-redis; then
    sleep 0.5
    if run exec -- redis-cli -p 16379 PING | grep -q PONG; then
      ok "redis PING"
      run exec -- redis-cli -p 16379 SET capbox:key 'CapBox Redis works' >/dev/null
      if run exec -- redis-cli -p 16379 GET capbox:key | grep -q 'CapBox Redis works'; then ok "redis SET/GET"; else bad "redis GET"; fi
    else bad "redis PING"; fi
    run service stop slow-redis || true
  else bad "redis start"; fi
else echo "  SKIP  redis 未安装"; fi

if run exec -- test -x /usr/bin/memcached; then
  write_env slow-memcached "CMD='memcached -p 11212 -u root -l 127.0.0.1 -m 64'
CWD=/"
  if run service start slow-memcached; then
    sleep 0.8
    out=$(python3 -c 'import socket;s=socket.create_connection(("127.0.0.1",11212),3);s.sendall(b"set capbox 0 0 19\r\nCapBox Memcached OK\r\nget capbox\r\nquit\r\n");print(s.recv(4096).decode(errors="replace"))')
    if printf '%s' "$out" | grep -q STORED && printf '%s' "$out" | grep -q 'CapBox Memcached OK'; then ok "memcached SET/GET"
    else bad "memcached SET/GET ($out)"; fi
    run service stop slow-memcached || true
  else bad "memcached start"; fi
else echo "  SKIP  memcached 未安装"; fi

if run exec -- sh -c 'command -v mysqld >/dev/null || command -v mariadbd >/dev/null'; then
  write_env slow-mariadb "CMD='mkdir -p /run/mysqld /workspace/service-test/mariadb; mysqld --datadir=/workspace/service-test/mariadb/data --socket=/workspace/service-test/mariadb/mysql.sock --pid-file=/workspace/service-test/mariadb/mysqld.pid --port=13307 --bind-address=127.0.0.1 --user=root'
CWD=/"
  if run service start slow-mariadb; then
    ready=0
    for i in $(seq 1 40); do
      if run exec -- mariadb-admin --socket=/workspace/service-test/mariadb/mysql.sock ping 2>/dev/null | grep -qi alive \
        || run exec -- mysqladmin --socket=/workspace/service-test/mariadb/mysql.sock ping 2>/dev/null | grep -qi alive; then
        ready=1; break
      fi
      sleep 0.25
    done
    if (( ready == 1 )); then
      ok "mariadb ping"
      run exec -- mariadb --socket=/workspace/service-test/mariadb/mysql.sock -e "CREATE DATABASE IF NOT EXISTS capbox; USE capbox; CREATE TABLE IF NOT EXISTS items(id INT PRIMARY KEY, name VARCHAR(64)); INSERT INTO items VALUES (1,'MariaDB inside CapBox') ON DUPLICATE KEY UPDATE name=VALUES(name);" \
        || run exec -- mysql --socket=/workspace/service-test/mariadb/mysql.sock -e "CREATE DATABASE IF NOT EXISTS capbox; USE capbox; CREATE TABLE IF NOT EXISTS items(id INT PRIMARY KEY, name VARCHAR(64)); INSERT INTO items VALUES (1,'MariaDB inside CapBox') ON DUPLICATE KEY UPDATE name=VALUES(name);"
      if run exec -- mariadb --socket=/workspace/service-test/mariadb/mysql.sock -N -e "SELECT name FROM capbox.items WHERE id=1" 2>/dev/null | grep -q 'MariaDB inside CapBox' \
        || run exec -- mysql --socket=/workspace/service-test/mariadb/mysql.sock -N -e "SELECT name FROM capbox.items WHERE id=1" 2>/dev/null | grep -q 'MariaDB inside CapBox'; then
        ok "mariadb SQL"
      else bad "mariadb SQL"; fi
    else bad "mariadb ping"; run service logs slow-mariadb -n 40 || true; fi
    run service stop slow-mariadb || true
  else bad "mariadb start"; run service logs slow-mariadb -n 40 || true; fi
else echo "  SKIP  mariadb 未安装"; fi

if run exec -- test -x /usr/sbin/sshd && [[ -f $SLOW_ROOT/service-test/sshd/sshd_config ]]; then
  [[ -f $SLOW_ROOT/service-test/sshd/client_ed25519_key.pub ]] && cp -f "$SLOW_ROOT/service-test/sshd/client_ed25519_key.pub" "$SLOW_ROOT/service-test/sshd/authorized_keys"
  run exec -- sh -c 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; cp /workspace/service-test/sshd/authorized_keys /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys' || true
  write_env slow-sshd "CMD='mkdir -p /run/sshd; /usr/sbin/sshd -D -f /workspace/service-test/sshd/sshd_config -e'
CWD=/
REQUIRE_IDMAP=1"
  if run service start slow-sshd; then
    sleep 0.8
    ssh_ok=0
    if command -v ssh >/dev/null; then
      if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SLOW_ROOT/service-test/sshd/client_ed25519_key" -p 12222 root@127.0.0.1 'echo CapBoxSSH_OK' 2>/dev/null | grep -q CapBoxSSH_OK; then ssh_ok=1; fi
    fi
    if (( ssh_ok == 0 )); then
      if run exec -- ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /workspace/service-test/sshd/client_ed25519_key -p 12222 root@127.0.0.1 'echo CapBoxSSH_OK' 2>/dev/null | grep -q CapBoxSSH_OK; then ssh_ok=1; fi
    fi
    if (( ssh_ok == 1 )); then ok "sshd 密钥登录"; else bad "sshd 密钥登录"; run service logs slow-sshd -n 50 || true; fi
    run service stop slow-sshd || true
  else bad "sshd start"; run service logs slow-sshd -n 40 || true; fi
else echo "  SKIP  sshd 未安装或缺少配置"; fi

echo
echo "[slow] 汇总: PASS=$pass FAIL=$fail"
(( fail == 0 ))

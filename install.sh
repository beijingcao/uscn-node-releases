#!/bin/bash
# USCN regional node installer (R63). Served by the center with its configured
# API origin. One command installs, repairs (rerun) or uninstalls a node:
#   install:   curl -fsSL <center>/api/v1/uscn/node/install.sh | sudo bash -s -- --code <code>
#   repair:    curl -fsSL <center>/api/v1/uscn/node/install.sh | sudo bash
#   uninstall: curl -fsSL <center>/api/v1/uscn/node/install.sh | sudo bash -s -- --uninstall [--purge]
# The same file is mirrored on GitHub; that copy needs --center <center origin>.
set -euo pipefail
CENTER='__USCN_CENTER_ORIGIN__'
API="$CENTER/api/v1/uscn/node"
BIN=/opt/uscn/bin
ETC=/etc/uscn
STATE=/var/lib/uscn
UNITDIR=/etc/systemd/system
code=""
center_arg=""
action=install
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --code) code="${2:-}"; shift 2 ;;
    --center) center_arg="${2:-}"; shift 2 ;;
    --uninstall) action=uninstall; shift ;;
    --purge) purge=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
die() { echo "安装停止：$*" >&2; exit 1; }
if [ "$CENTER" = "__USCN_CENTER_""ORIGIN__" ]; then
  # GitHub copy: the center origin comes from the administrator command.
  printf '%s' "$center_arg" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$' || die "请复制后台生成的完整命令（含 --center 中心地址）"
  CENTER="$center_arg"
  API="$CENTER/api/v1/uscn/node"
fi
[ "$(id -u)" = 0 ] || die "请用 root 运行（在命令前加 sudo）"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "仅支持 Linux amd64"

units="uscn-runtime.service uscn-https.service uscn-https-restart.path uscn-https-restart.service uscn-runtime-rollback.service"

stop_legacy_https() {
  # Pre-R63 nodes ran Caddy in Docker under /opt/uscn/https-ingress.
  if [ -f /opt/uscn/https-ingress/compose.yaml ] && command -v docker >/dev/null 2>&1; then
    docker compose -f /opt/uscn/https-ingress/compose.yaml --project-directory /opt/uscn/https-ingress down >/dev/null 2>&1 || true
  fi
}

if [ "$action" = uninstall ]; then
  systemctl disable --now uscn-https-restart.path uscn-https.service uscn-runtime.service >/dev/null 2>&1 || true
  for u in $units; do rm -f "$UNITDIR/$u"; done
  systemctl daemon-reload
  stop_legacy_https
  rm -rf /opt/uscn
  if [ "$purge" = 1 ]; then
    rm -rf "$ETC" "$STATE"
    userdel uscn >/dev/null 2>&1 || true
    echo "已卸载，并删除了节点身份与数据。"
  else
    echo "已卸载程序；节点身份与数据保留在 ${ETC} 和 ${STATE}。"
  fi
  exit 0
fi

for c in curl sha256sum runuser od gzip; do command -v "$c" >/dev/null 2>&1 || die "缺少命令 $c"; done
id uscn >/dev/null 2>&1 || useradd --system --home-dir "$STATE" --shell /usr/sbin/nologin uscn
install -d -m 0755 -o root -g root /opt/uscn "$ETC"
install -d -m 0755 -o uscn -g uscn "$BIN"
install -d -m 0700 -o uscn -g uscn "$ETC/private" "$STATE" "$STATE/custody" "$STATE/https"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; rm -f "$STATE/.enroll-code"' EXIT
if [ -f "$STATE/identity.json" ]; then
  [ -z "$code" ] || die "本机已登记过节点；修复安装请去掉 --code。要换成新节点，先在后台删除旧节点，再运行 --uninstall --purge"
  cred=$(sed -n 's/.*"credential": *"\([A-Za-z0-9_-]\{43\}\)".*/\1/p' "$STATE/identity.json")
  [ -n "$cred" ] || die "本机身份文件无法读取"
  printf 'Authorization: Bearer %s\n' "$cred" > "$tmp/auth"
else
  [ -n "$code" ] || die "请复制后台生成的完整安装命令（含 --code）"
  printf 'X-USCN-Enrollment-Code: %s\n' "$code" > "$tmp/auth"
fi
chmod 600 "$tmp/auth"
fetch() { curl -fsS --proto =https --retry 3 --connect-timeout 20 --max-time 600 -H @"$tmp/auth" "$@"; }

echo "从中心下载节点程序……"
fetch "$API/artifacts/latest/manifest" -o "$tmp/manifest" || die "无法从中心获取版本清单（连接码可能已过期，请在后台重新生成）"
version=$(sed -n 's/^version \([a-f0-9]\{40\}\)$/\1/p' "$tmp/manifest")
[ -n "$version" ] || die "中心没有可用的节点程序版本"
grep -E '^[a-f0-9]{64}  (uscn-runtime|caddy|Caddyfile)$' "$tmp/manifest" > "$tmp/SHA256SUMS" || true
[ "$(wc -l < "$tmp/SHA256SUMS")" = 3 ] || die "版本清单不完整"
# Fast mirror first (public GitHub release, gzip copies); each file is checked
# against the center manifest and falls back to the center on any failure.
source_base=$(sed -n 's#^source \(https://github\.com/[A-Za-z0-9_./-]*\)$#\1#p' "$tmp/manifest")
for f in uscn-runtime caddy Caddyfile; do
  want=$(awk -v f="$f" '$2==f {print $1}' "$tmp/SHA256SUMS")
  if [ -n "$source_base" ] && curl -fsSL --proto =https --retry 2 --connect-timeout 20 --max-time 600 "$source_base/$f.gz" | gzip -dc > "$tmp/$f" 2>/dev/null \
     && [ "$(sha256sum "$tmp/$f" | cut -d' ' -f1)" = "$want" ]; then
    continue
  fi
  [ -z "$source_base" ] || echo "GitHub 下载 $f 未成功，改从中心下载……"
  fetch "$API/artifacts/$version/$f" -o "$tmp/$f" || die "下载 $f 失败"
done
(cd "$tmp" && sha256sum -c --quiet SHA256SUMS) || die "下载文件校验失败"

systemctl stop uscn-https.service uscn-runtime.service >/dev/null 2>&1 || true
stop_legacy_https
for f in uscn-runtime caddy; do
  install -m 0755 -o uscn -g uscn "$tmp/$f" "$BIN/$f.new"
  mv -f "$BIN/$f.new" "$BIN/$f"
done
install -m 0644 -o uscn -g uscn "$tmp/Caddyfile" "$STATE/Caddyfile.template"
if [ ! -s "$ETC/custody-master.key" ]; then
  ( umask 077; { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; echo; } > "$ETC/custody-master.key" )
fi
chmod 600 "$ETC/custody-master.key"

if [ ! -f "$STATE/identity.json" ]; then
  echo "向中心登记本节点……"
  printf '%s\n' "$code" > "$STATE/.enroll-code"
  chown uscn:uscn "$STATE/.enroll-code"
  chmod 600 "$STATE/.enroll-code"
  runuser -u uscn -- "$BIN/uscn-runtime" enroll --center-url "$CENTER" --token-file "$STATE/.enroll-code" --identity-file "$STATE/identity.json" \
    || die "登记失败（原因见上方）。连接码只能用一次，请在后台为该节点重新生成命令"
  rm -f "$STATE/.enroll-code"
fi
runuser -u uscn -- "$BIN/uscn-runtime" setup --center-url "$CENTER" || die "节点配置失败（原因见上方）"

cat > "$UNITDIR/uscn-runtime.service" <<'UNIT'
[Unit]
Description=USCN regional node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5
OnFailure=uscn-runtime-rollback.service

[Service]
Type=simple
User=uscn
Group=uscn
WorkingDirectory=/var/lib/uscn
EnvironmentFile=/var/lib/uscn/runtime.env
LoadCredential=custody-key:/etc/uscn/custody-master.key
ExecStart=/usr/bin/env USCN_CUSTODY_KEY_FILE=${CREDENTIALS_DIRECTORY}/custody-key /opt/uscn/bin/uscn-runtime
Restart=always
RestartSec=5
TimeoutStopSec=120
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/uscn /opt/uscn/bin /etc/uscn/private

[Install]
WantedBy=multi-user.target
UNIT
cat > "$UNITDIR/uscn-runtime-rollback.service" <<'UNIT'
[Unit]
Description=USCN node rollback to the previous program after repeated start failures

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -x /opt/uscn/bin/uscn-runtime.prev ]; then mv -f /opt/uscn/bin/uscn-runtime.prev /opt/uscn/bin/uscn-runtime; systemctl reset-failed uscn-runtime.service; systemctl start uscn-runtime.service; fi'
UNIT
cat > "$UNITDIR/uscn-https.service" <<'UNIT'
[Unit]
Description=USCN node public HTTPS entry (Caddy)
After=network-online.target uscn-runtime.service
Wants=network-online.target

[Service]
Type=simple
User=uscn
Group=uscn
EnvironmentFile=/var/lib/uscn/https.env
Environment=XDG_DATA_HOME=/var/lib/uscn/https XDG_CONFIG_HOME=/var/lib/uscn/https/config
ExecStart=/opt/uscn/bin/caddy run --config /var/lib/uscn/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/uscn/https

[Install]
WantedBy=multi-user.target
UNIT
cat > "$UNITDIR/uscn-https-restart.path" <<'UNIT'
[Unit]
Description=Restart USCN HTTPS entry when the node agent updates it

[Path]
PathChanged=/var/lib/uscn/https.restart

[Install]
WantedBy=multi-user.target
UNIT
cat > "$UNITDIR/uscn-https-restart.service" <<'UNIT'
[Unit]
Description=Restart USCN HTTPS entry

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart uscn-https.service
UNIT

if ss -Hltn 'sport = :443' 2>/dev/null | grep -q .; then
  die "443 端口已被其他程序占用；请先停用它（例如原有 Nginx/Caddy/1Panel 站点）"
fi
systemctl daemon-reload
systemctl enable uscn-runtime.service uscn-https.service uscn-https-restart.path >/dev/null
systemctl reset-failed uscn-runtime.service >/dev/null 2>&1 || true
systemctl restart uscn-runtime.service
systemctl restart uscn-https.service
systemctl restart uscn-https-restart.path
for _ in $(seq 1 30); do
  systemctl is-active --quiet uscn-runtime.service && break
  sleep 2
done
systemctl is-active --quiet uscn-runtime.service || die "节点程序未能启动；查看：journalctl -u uscn-runtime -n 50"
echo "完成：节点程序 ${version:0:7} 已运行。公网 HTTPS 证书约 1 分钟内签发，之后中心自动核验。"
echo "回到后台节点列表，看到“在线”后点击“启用”。"

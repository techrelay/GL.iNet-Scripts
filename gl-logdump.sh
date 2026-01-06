#!/bin/sh
# gl-logbundle.sh - collect a support bundle on OpenWrt/GL.iNet
# Output: /tmp/gl-bundle-<hostname>-<timestamp>.tar.gz
set -eu

OUTDIR="/tmp/gl-bundle.$$"
HOST="$(uci -q get system.@system[0].hostname || hostname || echo glinet)"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || date)"
OUT="/tmp/gl-bundle-${HOST}-${TS}.tar.gz"

mkdir -p "$OUTDIR"

run() {
  name="$1"; shift
  ( "$@" ) >"$OUTDIR/$name" 2>&1 || true
}

# Core system info
run 00-system.txt uname -a
run 01-uptime.txt uptime
run 02-df.txt df -h
run 03-mem.txt free || true
run 04-ps.txt ps w

# Network state
run 10-ip-addr.txt ip addr
run 11-ip-route.txt ip route
run 12-ifstatus-wan.json ifstatus wan
run 13-ifstatus-lan.json ifstatus lan
run 14-resolv.conf.txt cat /tmp/resolv.conf.auto
run 15-arp.txt ip neigh || arp -a

# Config (read-only)
run 20-uci-network.txt uci show network
run 21-uci-firewall.txt uci show firewall
run 22-uci-wireless.txt uci show wireless
run 23-uci-dhcp.txt uci show dhcp
run 24-uci-system.txt uci show system
run 25-uci-glinet.txt uci show glinet || true

# Logs
run 30-logread.txt logread
run 31-dmesg.txt dmesg
[ -f /etc/openwrt_release ] && cp /etc/openwrt_release "$OUTDIR/40-openwrt_release.txt" || true
[ -f /etc/os-release ] && cp /etc/os-release "$OUTDIR/41-os-release.txt" || true

# Optional: modem info if gl_modem exists
if command -v gl_modem >/dev/null 2>&1; then
  # Try to list modem buses (best effort)
  run 50-gl_modem-help.txt gl_modem -h
fi

# Basic redaction pass (best-effort, not perfect)
# Redact strings like password=, key=, token= in UCI dumps
for f in "$OUTDIR"/2*-uci-*.txt; do
  [ -f "$f" ] || continue
  sed -i \
    -e 's/\(password=\).*/\1<redacted>/g' \
    -e 's/\(key=\).*/\1<redacted>/g' \
    -e 's/\(token=\).*/\1<redacted>/g' \
    -e 's/\(secret=\).*/\1<redacted>/g' \
    "$f" 2>/dev/null || true
done

tar -czf "$OUT" -C "$OUTDIR" .
rm -rf "$OUTDIR"

echo "$OUT"

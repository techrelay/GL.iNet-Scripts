#!/bin/sh
# gl-logbundle.sh - GL.iNet/OpenWrt support bundle + modem/cellular dump 
# Output: /tmp/gl-bundle-<hostname>-<timestamp>.tar.gz
# Usage: gl-logbundle.sh
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

# -----------------------------
# Modem/Cellular dump
# -----------------------------
modem_dump() {
  OUTFILE="$1"

  w() { printf "%s\n" "$*" >>"$OUTFILE"; }
  cmd() { w ""; w "### $*"; ( "$@" ) >>"$OUTFILE" 2>&1 || true; }

  find_buses() {
    # 1) From glconfig 
    if [ -f /etc/config/glconfig ]; then
      grep -E "list[[:space:]]+bus" /etc/config/glconfig 2>/dev/null \
        | sed -n "s/.*list[[:space:]]\+bus[[:space:]]\+'\([^']\+\)'.*/\1/p"
    fi

    # 2) From process args containing "-B <bus>"
    ps w 2>/dev/null \
      | grep -E "gl_modem|modem" \
      | grep -E "\-B[[:space:]]" \
      | sed -n 's/.*-B[[:space:]]\([^[:space:]]\+\).*/\1/p'

    # 3) Heuristic from dmesg USB bus lines
    dmesg 2>/dev/null \
      | grep -E "usb [0-9]+-[0-9]+(\.[0-9]+)?" \
      | sed -n 's/.*usb \([0-9]\+-[0-9]\+\(\.[0-9]\+\)\?\).*/\1/p'

    # 4) Sometimes stored here on some builds
    if uci -q show board_special.hardware.usb_port >/dev/null 2>&1; then
      uci -q get board_special.hardware.usb_port 2>/dev/null || true
    fi
  }

  dedupe() { awk 'NF && !seen[$0]++ {print}'; }

  : >"$OUTFILE"
  w "GL.iNet Modem/Cellular Dump"
  w "Host: $HOST"
  w "Time: $(date -Iseconds 2>/dev/null || date)"
  w ""

  # Baseline info that helps even if no modem
  cmd ip link
  cmd ip addr
  cmd ip route
  cmd logread -e modem
  cmd logread -e qmi
  cmd logread -e mbim
  cmd logread -e mhi
  cmd dmesg

  # If gl_modem isn't present, stop
  if ! command -v gl_modem >/dev/null 2>&1; then
    w ""
    w "gl_modem not found on this firmware."
    w "If this is a non-cellular model (e.g. BE9300 without USB modem), this is expected."
    return 0
  fi

  BUSES="$(find_buses | dedupe || true)"

  w ""
  w "Discovered bus candidates:"
  if [ -n "${BUSES:-}" ]; then
    echo "$BUSES" | while IFS= read -r b; do w " - $b"; done
  else
    w " (none)"
  fi

  if [ -z "${BUSES:-}" ]; then
    w ""
    w "No modem bus detected."
    w "If this device is not a cellular model, this is expected."
    w "If using a USB modem, plug it in and check: dmesg | grep -E 'ttyUSB|cdc-wdm|qmi_wwan|mbim|mhi'"
    return 0
  fi

  # For each bus, AT queries 
  for BUS in $BUSES; do
    w ""
    w "=============================="
    w "BUS: $BUS"
    w "=============================="

    cmd gl_modem -B "$BUS" AT ATI
    cmd gl_modem -B "$BUS" AT AT+CGMM
    cmd gl_modem -B "$BUS" AT AT+CGMR
    cmd gl_modem -B "$BUS" AT AT+CSQ
    cmd gl_modem -B "$BUS" AT AT+CPIN?
    cmd gl_modem -B "$BUS" AT AT+COPS?
    cmd gl_modem -B "$BUS" AT AT+CREG?
    cmd gl_modem -B "$BUS" AT AT+CEREG?
    cmd gl_modem -B "$BUS" AT AT+CGPADDR

    # Quectel-ish 
    cmd gl_modem -B "$BUS" AT AT+QGMR
    cmd gl_modem -B "$BUS" AT AT+QNWINFO
  done

  return 0
}

# -----------------------------
# Collect bundle
# -----------------------------

# Core system info
run 00-system.txt uname -a
run 01-uptime.txt uptime
run 02-df.txt df -h
run 03-mem.txt sh -c 'free 2>/dev/null || echo "free not available"'
run 04-ps.txt ps w

# Network state
run 10-ip-addr.txt ip addr
run 11-ip-route.txt ip route
run 12-ifstatus-wan.json ifstatus wan
run 13-ifstatus-lan.json ifstatus lan
run 14-resolv.conf.txt sh -c 'cat /tmp/resolv.conf.auto 2>/dev/null || cat /etc/resolv.conf 2>/dev/null || true'
run 15-neigh.txt sh -c 'ip neigh 2>/dev/null || arp -a 2>/dev/null || true'

# Config (read-only)
run 20-uci-network.txt uci show network
run 21-uci-firewall.txt uci show firewall
run 22-uci-wireless.txt uci show wireless
run 23-uci-dhcp.txt uci show dhcp
run 24-uci-system.txt uci show system
run 25-uci-glinet.txt sh -c 'uci show glinet 2>/dev/null || true'
run 26-uci-glconfig.txt sh -c 'cat /etc/config/glconfig 2>/dev/null || true'

# Logs
run 30-logread.txt logread
run 31-dmesg.txt dmesg

[ -f /etc/openwrt_release ] && cp /etc/openwrt_release "$OUTDIR/40-openwrt_release.txt" || true
[ -f /etc/os-release ] && cp /etc/os-release "$OUTDIR/41-os-release.txt" || true

# Modem/Cellular dump (combined)
modem_dump "$OUTDIR/50-modem-dump.txt"

# Basic redaction pass 
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

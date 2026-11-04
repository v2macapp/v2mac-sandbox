#!/bin/sh
# Host leak check (plan §9 "Host-level"): captures the physical NIC with each packet's sending process
# while you run probes and scenarios, then lists who sent what. Pass: the VM process and the helper send
# nothing on the NIC; the sandbox core's xray only reaches its server IPs.
# Exit 0 = pass, 1 = fail, 2 = INCONCLUSIVE (the capture did not run or caught nothing).
#   sudo Scripts/host-leak.sh [interface] [seconds]   (Ctrl-C ends early; default: default route, 300 s)
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
IF=${1:-$(route -n get default | awk '/interface:/ {print $2}')}
OUT=${TMPDIR:-/tmp}/v2mac-host-leak-$(date +%s).txt
echo "Capturing $IF for ${2:-300} s into $OUT; run the probes and scenarios now."
# -k NP: process name and pid per packet; -q -n: short lines, no DNS lookups of our own.
tcpdump -i "pktap,$IF" -k NP -n -q -l > "$OUT" & pid=$!
trap 'kill $pid 2>/dev/null' INT
sleep 1
kill -0 $pid 2>/dev/null || { echo "INCONCLUSIVE: tcpdump did not start (its error is above)"; exit 2; }
sleep "${2:-300}" || true
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
[ -s "$OUT" ] || { echo "INCONCLUSIVE: the capture is empty, so nothing was measured"; exit 2; }
echo "== packets per process"
sed -n 's/.*proc \([^:,)]*\):\([0-9]*\).*/\1/p' "$OUT" | sort | uniq -c | sort -rn
echo "== destinations of sandbox processes (xray started by the helper, the helper, the VM)"
# Per pid: the main V2Mac's xray and the sandbox core are both "xray" (`ps -p <pid> -o ppid,command` tells them apart).
grep -E 'proc (xray|V2Mac Sandbox|com.apple.Virtualization)' "$OUT" |
  sed -n 's/.*proc \([^,)]*\).* > \([0-9a-f.:]*\)\.[0-9]*: .*/\1 → \2/p' | sort | uniq -c | sort -rn
if grep -qE 'proc (V2Mac Sandbox|com.apple.Virtualization)' "$OUT"; then echo "FAIL: the helper or the VM sent packets on $IF"; exit 1; fi
echo "Helper and VM sent nothing on $IF. Check that every xray destination above is a server IP. Full log: $OUT"

#!/bin/sh
# NetSight remote collector  —  PUSH MODE (fallback)
# ==================================================
# Streams a capture feed from a box with a better view of the network than your Mac has,
# so NetSight can attribute traffic and site visits to EVERY device — not just this Mac.
#
# PREFER THE BUILT-IN SSH COLLECTOR INSTEAD
#   NetSight's Scan tab can dial the box itself over SSH: add "root@<host>" there and it
#   runs the same tcpdump remotely, reads it over the SSH channel, and tears it down when
#   the app quits. That path needs no script, no open port, and no firewall change.
#   Use THIS script only when the Mac cannot SSH to the box with key auth (BatchMode).
#
#   Caveat for push mode: macOS's application firewall silently drops inbound connections
#   to a locally-built, ad-hoc-signed app — its allow entry goes stale every rebuild. If
#   this script connects but NetSight shows nothing, that is why. Allow NetSight.app for
#   incoming connections in System Settings > Network > Firewall, or use the SSH path.
#
# WHY A COLLECTOR IS NEEDED AT ALL
#   NetSight sniffs the Mac's own NIC. On a switched LAN that means it sees the Mac's
#   traffic plus everyone's broadcasts — an iPhone talking to Netflix never reaches it.
#   Run a collector on the gateway (best) or a switch mirror port and that blind spot closes.
#
# USAGE
#   sudo sh netsight-collector.sh <mac-ip> <token> [iface] [mode] [port]
#
#     mac-ip   where NetSight is running          e.g. 192.0.2.153
#     token    from NetSight's Scan tab           e.g. 4f9c1a...
#     iface    interface to capture on            default: auto-detected
#     mode     dns | flows | both                 default: dns
#     port     NetSight listener port             default: 9999
#
# MODES — pick deliberately, they cost very different amounts
#   dns    (default) Only DNS queries. Tiny load, small stream, and it is what powers
#          per-device site history: "what Facebook sites did the iPhone visit today".
#          A busy home network produces a few queries per second. Safe to leave running.
#   flows  Every packet header. Gives per-device byte volumes and connection counts,
#          but on a gateway during a large download this is tens of thousands of lines
#          per second. Use when you want volume accounting and the box can afford it.
#   both   Both streams, as two connections.
#
# SAFETY
#   Read-only: it captures and forwards, and never writes to disk or alters traffic.
#   Reconnects on its own if NetSight restarts. Ctrl-C stops it and kills its tcpdumps.
#   Remove it by stopping it — it installs nothing.
#
# EXAMPLES
#   sudo sh netsight-collector.sh 192.0.2.153 4f9c1a2b3c4d
#   sudo sh netsight-collector.sh 192.0.2.153 4f9c1a2b3c4d br0 both
set -eu

MAC_IP="${1:-}"
TOKEN="${2:-}"
IFACE="${3:-auto}"
MODE="${4:-dns}"
PORT="${5:-9999}"

if [ -z "$MAC_IP" ] || [ -z "$TOKEN" ]; then
    echo "usage: sudo sh netsight-collector.sh <mac-ip> <token> [iface] [mode: dns|flows|both] [port]" >&2
    echo "       the token is shown in NetSight's Scan tab" >&2
    exit 2
fi

# Auto-detect the interface that carries the default route; that is the one that
# sees traffic on a gateway or a normal host.
if [ "$IFACE" = "auto" ]; then
    IFACE=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    [ -z "$IFACE" ] && IFACE=$(route -n get default 2>/dev/null | sed -n 's/.*interface: *//p' | head -1)
    [ -z "$IFACE" ] && IFACE=eth0
fi

command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump not found on this box" >&2; exit 3; }
command -v nc >/dev/null 2>&1 || { echo "nc (netcat) not found on this box" >&2; exit 3; }

# Never capture our own control stream back into NetSight.
EXCLUDE="not (host $MAC_IP and port $PORT)"

PIDS=""
cleanup() {
    trap - INT TERM EXIT
    [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
    echo ""
    echo "collector stopped."
    exit 0
}
trap cleanup INT TERM EXIT

# One channel = one reconnecting loop = one TCP connection to NetSight.
#   $1 channel letter (D|F), $2 tcpdump filter, $3 extra tcpdump args
start_channel() {
    ch="$1"; filter="$2"; extra="$3"
    (
        while :; do
            # The handshake line first, then the capture stream, all down one pipe.
            { printf 'NETSIGHT1 %s %s\n' "$TOKEN" "$ch"
              # shellcheck disable=SC2086
              tcpdump -i "$IFACE" -nn -t -l $extra "$filter" 2>/dev/null
            } | nc "$MAC_IP" "$PORT" 2>/dev/null || true
            # NetSight closed, restarted, or the link dropped — wait and re-offer.
            sleep 5
        done
    ) &
    PIDS="$PIDS $!"
    echo "  channel $ch  -> $MAC_IP:$PORT   ($filter)"
}

echo "NetSight collector"
echo "  interface : $IFACE"
echo "  mode      : $MODE"
case "$MODE" in
    dns)   start_channel D "udp port 53 and ($EXCLUDE)" "-s 512" ;;
    flows) start_channel F "$EXCLUDE" "-q" ;;
    both)  start_channel D "udp port 53 and ($EXCLUDE)" "-s 512"
           start_channel F "$EXCLUDE" "-q" ;;
    *)     echo "unknown mode '$MODE' (use dns, flows, or both)" >&2; exit 2 ;;
esac
echo ""
echo "Streaming. NetSight's Scan tab will show this collector as connected."
echo "Press Ctrl-C to stop."
wait

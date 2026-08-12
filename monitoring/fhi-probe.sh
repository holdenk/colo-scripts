#!/usr/bin/env bash
# fhi-probe.sh -- multi-vantage availability prober for Fight Health Insurance.
#
# When an external monitor (e.g. UptimeRobot) reports "Connection Timeout",
# these timestamped measurements let us say WHICH leg actually failed:
#
#   target        what it measures
#   ------------  ------------------------------------------------------------
#   cf-ping-head  HEAD /ziggy/rest/ping via Cloudflare (the monitor's request)
#   cf-ping-get   GET  the same URL (method-sensitivity comparison)
#   cf-root       GET  / via Cloudflare (the comparison monitor that never fails)
#   origin-ping   GET  /ziggy/rest/ping pinned to $ORIGIN_IP -- bypasses Cloudflare
#   vip-ping      GET  /ziggy/rest/ping pinned to $VIP -- LAN ingress only
#
# Each probe appends one TSV line:
#   iso-ts  vantage  target  outcome  http_code  total_s  ttfb_s  cf_pop  cache_status
# outcome: ok | http-<code> | timeout | connect-fail | tls-fail | dns-fail | curl-<rc>
# cf_pop is the Cloudflare POP from the cf-ray header (e.g. IAD), so failures
# that cluster on one POP are visible. "-" where not applicable.
#
# How to read the results during a monitor incident:
#   cf-ping-* fail, cf-root + origin-ping ok  -> Cloudflare mitigating that
#                                                request pattern (DDoS/bot rules)
#   cf-ping-head fails, cf-ping-get ok        -> HEAD-specific mitigation
#   all cf-* fail on one POP, origin-ping ok  -> Cloudflare POP / path issue
#   origin-ping (and vip-ping) fail too       -> actually our colo; go look
#
# Usage:
#   VIP=10.42.0.200 ./fhi-probe.sh lan 30                # on a LAN host
#   ORIGIN_IP=<public ingress IP> ./fhi-probe.sh vps 30  # on a remote VPS
#   ./fhi-probe.sh summary logs/fhi-probe-vps-2026-07-19.tsv
#
# Run it forever under nohup/tmux/systemd; it writes one log file per day
# into $LOG_DIR (default: ./logs next to this script).

set -u

FHI_HOST="${FHI_HOST:-www.fighthealthinsurance.com}"
PING_PATH="${PING_PATH:-/ziggy/rest/ping}"
ORIGIN_IP="${ORIGIN_IP:-}"
VIP="${VIP:-}"
TIMEOUT="${TIMEOUT:-15}"
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"

if [ "${1:-}" = "summary" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 summary <log.tsv>" >&2; exit 1; }
  awk -F'\t' '
    { n[$3]++; if ($4 == "ok") ok[$3]++; else bad[$3 "|" $4]++
      if ($6 + 0 > max[$3]) max[$3] = $6; sum[$3] += $6 }
    END {
      for (t in n)
        printf "%-14s n=%-6d ok=%-6d avg=%.2fs max=%.2fs\n", t, n[t], ok[t], sum[t] / n[t], max[t]
      print "failures:"
      for (k in bad) { split(k, a, "|"); printf "  %-14s %-14s %d\n", a[1], a[2], bad[k] }
    }' "$2"
  exit 0
fi

VANTAGE="${1:?usage: $0 <vantage-name|summary> [interval-seconds]}"
INTERVAL="${2:-30}"
mkdir -p "$LOG_DIR"

probe() { # probe <target-name> <url> <resolve-spec|-> <extra-curl-arg|->
  name="$1" url="$2" resolve="$3" extra="$4"
  hdrs="$(mktemp)"
  args=(-sS -o /dev/null -D "$hdrs" -m "$TIMEOUT"
        -w '%{http_code} %{time_total} %{time_starttransfer}')
  if [ "$resolve" != "-" ]; then args+=(--resolve "$resolve"); fi
  if [ "$extra" != "-" ]; then args+=("$extra"); fi
  out="$(curl "${args[@]}" "$url" 2>/dev/null)"
  rc=$?
  code="${out%% *}"; rest="${out#* }"; total="${rest%% *}"; ttfb="${rest##* }"
  pop="$(sed -n 's/^[Cc][Ff]-[Rr]ay: .*-\([A-Z]\{3\}\).*/\1/p' "$hdrs" | head -1)"
  cache="$(sed -n 's/^[Cc][Ff]-[Cc]ache-[Ss]tatus: //p' "$hdrs" | head -1 | tr -d '\r')"
  rm -f "$hdrs"
  if [ "$rc" -eq 0 ]; then
    case "$code" in
      2* | 3*) outcome=ok ;;
      *) outcome="http-$code" ;;
    esac
  else
    case "$rc" in
      28) outcome=timeout ;;
      7) outcome=connect-fail ;;
      6) outcome=dns-fail ;;
      35 | 51 | 53 | 54 | 58 | 59 | 60 | 77 | 82 | 83 | 90 | 91) outcome=tls-fail ;;
      *) outcome="curl-$rc" ;;
    esac
    code="-" total="-" ttfb="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$VANTAGE" "$name" "$outcome" "$code" "$total" "$ttfb" \
    "${pop:--}" "${cache:--}" >> "$LOG_DIR/fhi-probe-$VANTAGE-$(date +%F).tsv"
}

echo "fhi-probe: vantage=$VANTAGE interval=${INTERVAL}s origin=${ORIGIN_IP:-unset} vip=${VIP:-unset} logs=$LOG_DIR"
while :; do
  probe cf-ping-head "https://$FHI_HOST$PING_PATH" - -I &
  probe cf-ping-get "https://$FHI_HOST$PING_PATH" - - &
  probe cf-root "https://$FHI_HOST/" - - &
  if [ -n "$ORIGIN_IP" ]; then
    probe origin-ping "https://$FHI_HOST$PING_PATH" "$FHI_HOST:443:$ORIGIN_IP" - &
  fi
  if [ -n "$VIP" ]; then
    probe vip-ping "https://$FHI_HOST$PING_PATH" "$FHI_HOST:443:$VIP" - &
  fi
  wait
  sleep "$INTERVAL"
done

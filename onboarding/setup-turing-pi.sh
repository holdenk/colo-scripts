#!/usr/bin/env bash
# setup-turing-pi.sh -- dynamically bring up and onboard Turing Pi 2 nodes.
#
# A Turing Pi 2 board has four module slots that can each hold a different
# compute module (Raspberry Pi CM4, Jetson, RK1, ...). Rather than hard-coding
# what lives where, this script drives the board's BMC (via the `tpi` CLI or the
# BMC REST API) to:
#   * optionally flash a fresh image onto a node's storage
#     (use images from make-pi-image.sh / make-jetson-image.sh)
#   * power the requested slots on (or off / reset)
#   * discover which slots actually came up by probing the network
#   * report which nodes are ready for the usual Ansible onboarding
#
# "Dynamic" means: we act on whatever slots you point it at, power them on, and
# then find out which ones answer -- empty or unpopulated slots are simply
# reported as "no response" instead of failing the run.
#
# The BMC connection is taken from flags or the environment:
#   TPI_HOST (BMC hostname/IP), TPI_USER, TPI_PASS
#
# Examples:
#   # power on every slot and wait for them to come up as tpi-node1..4
#   ./setup-turing-pi.sh --host turingpi.local --wait --node-prefix tpi-node
#
#   # flash a freshly-built Pi image to slot 2, power it, and wait for it
#   ./setup-turing-pi.sh --host turingpi.local \
#       --flash 2=pi-rpi3.img --nodes 2 --wait --node-host 2=rpi3
#
#   # just show what the board reports
#   ./setup-turing-pi.sh --host turingpi.local --power status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

bmc_host="${TPI_HOST:-}"
bmc_user="${TPI_USER:-}"
bmc_pass="${TPI_PASS:-}"
power_action="on"           # on | off | reset | status
nodes_arg=""                # e.g. "1 2 4"; empty => all four slots
node_prefix="${TPI_NODE_PREFIX:-}"
do_wait=false
wait_timeout=300
probe_user=""               # ssh user for --wait key-auth check (default: operator)
declare -A flash_map=()     # node -> image path
declare -A host_map=()      # node -> explicit hostname

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

  --host HOST           BMC hostname/IP (env TPI_HOST)
  --user USER           BMC user (env TPI_USER)
  --pass PASS           BMC password (env TPI_PASS)
  --power ACTION        on | off | reset | status   (default: on)
  --nodes "1 2 4"       slots to act on (default: all populated slots, 1-4)
  --flash NODE=IMAGE    flash IMAGE onto slot NODE before powering it on
                        (repeatable; implies that slot is in --nodes)
  --wait                after powering on, wait for each slot to answer on SSH
  --timeout SECONDS     how long to wait per slot with --wait (default: $wait_timeout)
  --node-prefix NAME    derive hostnames NAME1..NAME4 for --wait probing
  --node-host NODE=HOST explicit hostname for a slot (repeatable; overrides
                        --node-prefix for that slot)
  --probe-user NAME     ssh user for the --wait key-auth check; should match the
                        image's bootstrap user (default: the operator)
  -h, --help            show this help

Node hostnames (for --wait) are resolved per slot as, in order of precedence:
  --node-host NODE=HOST, then <--node-prefix><NODE>, each suffixed with
  .$COLO_DOMAIN unless already an FQDN.
EOF
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)        bmc_host="${2:?}"; shift 2 ;;
    --user)        bmc_user="${2:?}"; shift 2 ;;
    --pass)        bmc_pass="${2:?}"; shift 2 ;;
    --power)       power_action="${2:?}"; shift 2 ;;
    --nodes)       nodes_arg="${2:?}"; shift 2 ;;
    --node-prefix) node_prefix="${2:?}"; shift 2 ;;
    --wait)        do_wait=true; shift ;;
    --timeout)     wait_timeout="${2:?}"; shift 2 ;;
    --probe-user)  probe_user="${2:?}"; shift 2 ;;
    --flash)
      [[ "${2:-}" == *=* ]] || die "--flash expects NODE=IMAGE"
      flash_map["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --node-host)
      [[ "${2:-}" == *=* ]] || die "--node-host expects NODE=HOST"
      host_map["${2%%=*}"]="${2#*=}"; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)             warn "unknown argument: $1"; usage ;;
  esac
done

[[ -n "$bmc_host" ]] || die "BMC host is required (--host or TPI_HOST)"
case "$power_action" in on|off|reset|status) ;; *) die "invalid --power: $power_action" ;; esac
[[ "$power_action" == "status" && ${#flash_map[@]} -gt 0 ]] \
  && die "--flash conflicts with --power status (status is read-only and would silently skip the flash)"
# probe_node bounds each connect with timeout(1); without it a dropped SYN
# would block for the kernel's full retry cycle (~2 min) instead of --timeout.
$do_wait && require_cmds timeout
# Probe as the image's bootstrap user (the operator, unless overridden) -- the
# only account that can key-auth on a freshly-imaged node before ssh.yaml runs.
probe_user="${probe_user:-$(operator_user)}"

# Prefer the tpi CLI; fall back to the BMC REST API via curl.
have_tpi=false
if command -v tpi >/dev/null 2>&1; then
  have_tpi=true
else
  require_cmds curl
  warn "tpi CLI not found; using the BMC REST API via curl."
  warn "install tpi for a nicer experience: https://github.com/turing-machines/tpi"
fi

# tpi <args...>  -- run the tpi CLI with the configured BMC connection.
tpi() {
  local cmd=(command tpi --host "$bmc_host")
  [[ -n "$bmc_user" ]] && cmd+=(--user "$bmc_user")
  [[ -n "$bmc_pass" ]] && cmd+=(--password "$bmc_pass")
  "${cmd[@]}" "$@"
}

# bmc_api <query>  -- hit the BMC REST endpoint (fallback when tpi is absent).
bmc_api() {
  local query="$1" auth=()
  [[ -n "$bmc_user$bmc_pass" ]] && auth=(-u "${bmc_user}:${bmc_pass}")
  curl -fsSk "${auth[@]}" "https://${bmc_host}/api/bmc?${query}"
}

# node_power <node> <on|off|reset>
node_power() {
  local node="$1" action="$2"
  if $have_tpi; then
    tpi power "$action" --node "$node"
    return
  fi
  # Raw BMC REST fallback -- best effort. The power set uses 1-indexed
  # node1..node4 keys; reset is 0-indexed on some firmware and shaped
  # differently, so we punt that to the tpi CLI rather than guess.
  case "$action" in
    on)    bmc_api "opt=set&type=power&node${node}=1" >/dev/null ;;
    off)   bmc_api "opt=set&type=power&node${node}=0" >/dev/null ;;
    reset) die "power reset requires the tpi CLI (raw BMC reset varies by firmware)" ;;
  esac
}

# power_status  -- print whatever the board reports for all slots; fails
# loudly (callers decide whether that is fatal) instead of masking a 401 or
# unreachable BMC as an empty-but-successful report.
power_status() {
  if $have_tpi; then
    tpi power status
  else
    bmc_api "opt=get&type=power"
  fi
}

# node_hostname <node>  -- resolved hostname for a slot, or empty if unknown.
node_hostname() {
  local node="$1"
  if [[ -n "${host_map[$node]:-}" ]]; then
    fully_qualify "${host_map[$node]}"
  elif [[ -n "$node_prefix" ]]; then
    fully_qualify "${node_prefix}${node}"
  fi
}

# probe_node <host> <timeout>  -- watch for the node to come up; prints one of
#   auth  ssh key auth as the first admin works (truly ready for Ansible)
#   tcp   port 22 open but key auth unconfirmed (first-boot onboarding may
#         still be running, or no matching key is loaded on this workstation)
#   down  nothing answered before the deadline
probe_node() {
  local host="$1" timeout="$2" deadline tcp_up=false
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if ! $tcp_up; then
      # timeout(1) bounds the connect: a dropped SYN would otherwise block for
      # the kernel's full retry cycle (~2 min), blowing well past --timeout.
      timeout 5 bash -c "exec 3<>/dev/tcp/${host}/22" 2>/dev/null && tcp_up=true
    fi
    if $tcp_up; then
      command -v ssh >/dev/null 2>&1 || { echo tcp; return; }
      # Stateless probe: don't touch the operator's known_hosts, and don't let
      # a post-reimage host-key change turn a healthy node into a false "tcp".
      if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           "${probe_user}@${host}" true 2>/dev/null; then
        echo auth
        return
      fi
    fi
    sleep 5
  done
  if $tcp_up; then echo tcp; else echo down; fi
}

# --- resolve which slots to act on -----------------------------------------
declare -a nodes=()
if [[ -n "$nodes_arg" ]]; then
  read -ra nodes <<<"$nodes_arg"
else
  nodes=(1 2 3 4)
fi
# Any slot named in --flash is implicitly in scope.
for n in "${!flash_map[@]}"; do
  [[ " ${nodes[*]} " == *" $n "* ]] || nodes+=("$n")
done
for n in "${nodes[@]}"; do
  [[ "$n" =~ ^[1-4]$ ]] || die "node slots must be 1-4, got '$n'"
done

info "Turing Pi BMC: $bmc_host"
log "board status before changes:"
if ! power_status >&2; then
  bmc_err="could not read BMC power status (check --host/--user/--pass; BMC firmware >= 2.0 requires authentication)"
  [[ "$power_action" == "status" ]] && die "$bmc_err"
  warn "$bmc_err"
fi

# --- status-only mode -------------------------------------------------------
if [[ "$power_action" == "status" ]]; then
  exit 0
fi

# --- optional flashing (before power for a clean first boot) ----------------
if [[ ${#flash_map[@]} -gt 0 ]]; then
  $have_tpi || die "flashing requires the tpi CLI (install from https://github.com/turing-machines/tpi)"
  for node in "${nodes[@]}"; do
    img="${flash_map[$node]:-}"
    [[ -n "$img" ]] || continue
    [[ -f "$img" ]] || die "flash image for node $node not found: $img"
    info "flashing node $node <- $img (this can take several minutes)"
    tpi flash --node "$node" --image-path "$img"
  done
fi

# --- power action -----------------------------------------------------------
for node in "${nodes[@]}"; do
  info "power $power_action -> node $node"
  node_power "$node" "$power_action" || warn "power $power_action failed for node $node"
done

# --- discover which slots actually came up ----------------------------------
if $do_wait && [[ "$power_action" != "off" ]]; then
  echo >&2
  info "waiting up to ${wait_timeout}s (all slots probed in parallel) for nodes to answer on SSH"
  probe_dir="$(mktemp -d)"
  declare -a probed=() unknown=()
  for node in "${nodes[@]}"; do
    host="$(node_hostname "$node")"
    if [[ -z "$host" ]]; then
      warn "node $node: no hostname (pass --node-prefix or --node-host) -- skipping probe"
      unknown+=("$node")
      continue
    fi
    log "node $node: probing $host ..."
    probe_node "$host" "$wait_timeout" >"$probe_dir/$node" &
    probed+=("$node=$host")
  done
  wait

  declare -a ready=() pending=() nores=()
  for entry in "${probed[@]}"; do
    node="${entry%%=*}"; host="${entry#*=}"
    case "$(cat "$probe_dir/$node" 2>/dev/null)" in
      auth)
        info "node $node: $host is up (ssh key auth OK)"
        ready+=("$node=$host") ;;
      tcp)
        warn "node $node: $host has port 22 open but key auth isn't confirmed (first-boot onboarding may still be running, or no matching key is loaded here)"
        pending+=("$node=$host") ;;
      *)
        warn "node $node: $host did not answer (empty slot, still booting, or wrong hostname)"
        nores+=("$node=$host") ;;
    esac
  done
  rm -rf "$probe_dir"

  echo >&2
  info "summary:"
  printf '  ready:     %s\n' "${ready[*]:-none}" >&2
  [[ ${#pending[@]} -gt 0 ]] && printf '  port open: %s\n' "${pending[*]}" >&2
  printf '  no reply:  %s\n' "${nores[*]:-none}" >&2
  [[ ${#unknown[@]} -gt 0 ]] && printf '  no host:   %s\n' "${unknown[*]}" >&2

  if [[ $(( ${#ready[@]} + ${#pending[@]} )) -gt 0 ]]; then
    limit=""
    for entry in "${ready[@]}" "${pending[@]}"; do limit+="${limit:+,}${entry#*=}"; done
    cat >&2 <<EOF

Next steps for the nodes that answered:
  1. Add them to the right group in hosts.yaml (pis / arm-gpus).
  2. Onboard with Ansible, e.g.:
       ansible-playbook -i hosts.yaml --vault-id dev@secret \\
         --extra-vars @passwd.yml --limit ${limit} \\
         playbooks/ssh.yaml playbooks/k3s.yaml
EOF
  fi
fi

echo >&2
log "board status after changes:"
power_status >&2 || warn "could not read BMC power status"

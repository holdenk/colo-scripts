#!/bin/bash
# Ensure /db/encrypted (ecryptfs) is mounted on every Kubernetes node.
#
# Meant to be run periodically from cron on the Ansible control host. It just
# re-runs the idempotent playbooks/ecrypt-ensure.yaml, which mounts
# /db/encrypted on any node where it is not already mounted (e.g. after a
# reboot -- the fstab entry is intentionally "noauto" so the encrypted volume
# never auto-mounts without the key).
#
# Node list source:
#   * default   -- the "kubernetes" group from hosts.yaml (recommended/safer)
#   * --kubectl -- limit the run to nodes reported by `kubectl get nodes`
#                  (their names must match the inventory hostnames)
#
# Requirements on the host running this script:
#   * ansible + the collections from requirements.yaml
#   * the vault password source referenced by --vault-id (repo-root "secret")
#   * passwd.yml (vault) providing ecrypt_pw
#
# Install it with playbooks/ecrypt-cron.yaml, or by hand, e.g.:
#   */5 * * * * cd /path/to/colo-scripts && ./ensure-encrypted-mounts.sh \
#     >> ensure-encrypted-mounts.log 2>&1
set -euo pipefail

# Resolve repo root from this script's location so cron can call it by abs path.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

VAULT_ID="${ANSIBLE_VAULT_ID:-dev@secret}"
INVENTORY="${ANSIBLE_INVENTORY:-hosts.yaml}"
EXTRA_VARS_FILE="${ECRYPT_EXTRA_VARS:-passwd.yml}"

usage() {
  cat >&2 <<EOF
Usage: $0 [--kubectl] [--limit PATTERN] [-- <extra ansible-playbook args>]

  --kubectl        derive the node list from 'kubectl get nodes' instead of
                   running against the whole 'kubernetes' inventory group
  --limit PATTERN  restrict the run to an Ansible host pattern
EOF
  exit 1
}

use_kubectl=false
limit=""
passthru=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubectl) use_kubectl=true; shift ;;
    --limit) limit="${2:?--limit needs a value}"; shift 2 ;;
    --) shift; passthru=("$@"); break ;;
    -h|--help) usage ;;
    *) passthru+=("$1"); shift ;;
  esac
done

if $use_kubectl; then
  # Build an Ansible --limit from the live node list. Node names must match
  # inventory hostnames (or otherwise be reachable) for this to line up.
  limit="$(kubectl get nodes -o name | sed 's#^node/##' | paste -sd, -)"
  if [[ -z "$limit" ]]; then
    echo "ensure-encrypted-mounts: kubectl get nodes returned no nodes" >&2
    exit 1
  fi
fi

cmd=(ansible-playbook -i "$INVENTORY" --vault-id "$VAULT_ID"
     --extra-vars "@${EXTRA_VARS_FILE}")
[[ -n "$limit" ]] && cmd+=(--limit "$limit")
cmd+=(playbooks/ecrypt-ensure.yaml)
[[ ${#passthru[@]} -gt 0 ]] && cmd+=("${passthru[@]}")

echo "[$(date -Is)] running: ${cmd[*]}"
exec "${cmd[@]}"

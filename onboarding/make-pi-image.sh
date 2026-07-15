#!/usr/bin/env bash
# make-pi-image.sh -- build a ready-to-onboard Raspberry Pi image.
#
# Takes the stock Ubuntu Server "preinstalled" arm64 image for Raspberry Pi and
# bakes in a cloud-init config so the Pi comes up on the network with:
#   * its hostname set (under COLO_DOMAIN, default local.pigscanfly.ca)
#   * the colo admins (holden, warrick) created with passwordless sudo and their
#     GitHub SSH keys installed
#   * ssh enabled
#
# That is exactly the state playbooks/ssh.yaml + playbooks/k3s.yaml expect, so
# once the Pi is up you just add it to hosts.yaml (the "pis" group) and run the
# usual Ansible flow -- no keyboard/monitor needed.
#
# The result is an .img you can write to an SD card (or feed to
# setup-turing-pi.sh --flash for a Turing Pi CM4 slot). Optionally write it
# straight to a device with --device.
#
# Examples:
#   ./make-pi-image.sh --hostname rpi3
#   ./make-pi-image.sh --hostname erpi4 --device /dev/sdX
#   ./make-pi-image.sh --hostname rpi3 --output /tmp/rpi3.img --ip 10.0.0.53/24 --gateway 10.0.0.1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Ubuntu Server for Raspberry Pi (arm64, cloud-init enabled). Override with
# --image-url or --image if this point release ages out.
DEFAULT_IMAGE_URL="https://cdimage.ubuntu.com/releases/24.04.2/release/ubuntu-24.04.2-preinstalled-server-arm64+raspi.img.xz"
CACHE_DIR="${COLO_IMAGE_CACHE:-$SCRIPT_DIR/.cache}"

hostname=""
output=""
device=""
base_image=""
image_url="$DEFAULT_IMAGE_URL"
static_ip=""
gateway=""
nameservers="8.8.8.8,8.8.4.4"

usage() {
  cat >&2 <<EOF
Usage: $0 --hostname NAME [options]

  --hostname NAME     hostname for the new Pi (bare name is suffixed with
                      .$COLO_DOMAIN; pass an FQDN to override)
  --output FILE       write the customized image here
                      (default: ./pi-<hostname>.img)
  --device /dev/sdX   after building, dd the image onto this block device
                      (DESTRUCTIVE -- prompts first)
  --image FILE        use this already-downloaded/decompressed base .img
  --image-url URL     base image to download (default: Ubuntu 24.04 raspi)
  --ip CIDR           configure a static address (e.g. 10.0.0.53/24) instead
                      of DHCP; requires --gateway
  --gateway IP        default gateway for --ip
  --nameservers LIST  comma-separated DNS servers for --ip (default: $nameservers)
  -h, --help          show this help
EOF
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    hostname="${2:?}"; shift 2 ;;
    --output)      output="${2:?}"; shift 2 ;;
    --device)      device="${2:?}"; shift 2 ;;
    --image)       base_image="${2:?}"; shift 2 ;;
    --image-url)   image_url="${2:?}"; shift 2 ;;
    --ip)          static_ip="${2:?}"; shift 2 ;;
    --gateway)     gateway="${2:?}"; shift 2 ;;
    --nameservers) nameservers="${2:?}"; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)             warn "unknown argument: $1"; usage ;;
  esac
done

[[ -n "$hostname" ]] || { warn "--hostname is required"; usage; }
[[ -z "$static_ip" || -n "$gateway" ]] || die "--ip requires --gateway"

require_cmds curl xz losetup mount umount blkid

fqdn="$(fully_qualify "$hostname")"
short="${fqdn%%.*}"
output="${output:-pi-${short}.img}"

# 1. Fetch the admins' keys up front -- a GitHub hiccup should cost seconds,
#    not a multi-GB image copy. emit_cloud_init_users dies if any admin's
#    keys can't be fetched.
info "fetching admin SSH keys"
users_block="$(emit_cloud_init_users)"

# 2. Get and stage a private copy of the base image so the cached download
#    stays pristine and re-runnable.
if [[ -n "$base_image" ]]; then
  [[ -f "$base_image" ]] || die "--image not found: $base_image"
  src_img="$base_image"
else
  src_img="$(resolve_base_image "$image_url" "$CACHE_DIR")"
fi

info "staging base image -> $output"
cp --reflink=auto "$src_img" "$output"

# 3. Mount the boot (vfat) partition where cloud-init reads its seed files.
loopdev=""
mnt=""
cleanup() {
  [[ -n "$mnt" && -d "$mnt" ]] && { as_root umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
  [[ -n "$loopdev" ]] && as_root losetup -d "$loopdev" 2>/dev/null || true
}
trap cleanup EXIT

loopdev="$(as_root losetup -Pf --show "$output")"
as_root partprobe "$loopdev" 2>/dev/null || true

boot_part="$(first_partition_of_type "$loopdev" vfat)" \
  || die "could not find a vfat boot partition in $output"
log "boot partition: $boot_part"

mnt="$(mktemp -d)"
as_root mount "$boot_part" "$mnt"

# 4. Write the cloud-init seed (user-data / meta-data / network-config).
info "writing cloud-init config for $fqdn"

# Note: no ssh_pwauth here. Setting it false makes cloud-init write a
# sshd_config.d drop-in that playbooks/ssh.yaml can't undo (it deliberately
# re-enables password auth as a break-glass path on every node).
{
  echo "#cloud-config"
  echo "hostname: $short"
  echo "fqdn: $fqdn"
  echo "prefer_fqdn_over_hostname: true"
  echo "manage_etc_hosts: true"
  echo "package_update: true"
  echo "packages:"
  echo "  - python3"          # so Ansible can run without a bootstrap step
  printf '%s\n' "$users_block"
  echo "runcmd:"
  echo "  - [ systemctl, enable, --now, ssh ]"
  echo "  - [ touch, /etc/colo-onboarded ]"
} | as_root tee "$mnt/user-data" >/dev/null

as_root tee "$mnt/meta-data" >/dev/null <<EOF
instance-id: $short
local-hostname: $short
EOF

if [[ -n "$static_ip" ]]; then
  ns_yaml=""
  IFS=',' read -ra _ns <<<"$nameservers"
  for n in "${_ns[@]}"; do ns_yaml+="          - $n"$'\n'; done
  as_root tee "$mnt/network-config" >/dev/null <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - $static_ip
    routes:
      - to: default
        via: $gateway
    nameservers:
      addresses:
$ns_yaml
EOF
else
  as_root tee "$mnt/network-config" >/dev/null <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
    optional: true
EOF
fi

as_root sync
info "image ready: $output"

# 5. Optionally flash it straight onto an SD card / USB device.
if [[ -n "$device" ]]; then
  [[ -b "$device" ]] || die "--device is not a block device: $device"
  # Release the loop mount before writing so nothing is holding the image.
  cleanup; trap - EXIT; loopdev=""; mnt=""
  warn "about to OVERWRITE $device with $output"
  as_root lsblk -o NAME,SIZE,MODEL "$device" >&2 || true
  read -r -p "Type 'yes' to continue: " confirm
  [[ "$confirm" == "yes" ]] || die "aborted"
  info "writing $output -> $device"
  as_root dd if="$output" of="$device" bs=4M conv=fsync status=progress
  as_root sync
  info "done -- $device is ready to boot"
fi

cat >&2 <<EOF

Next steps:
  1. Boot the Pi from this image on the colo network.
  2. Add '${fqdn}:' under the 'pis' group in hosts.yaml.
  3. Onboard it with Ansible, e.g.:
       ansible-playbook -i hosts.yaml --vault-id dev@secret \\
         --extra-vars @passwd.yml --limit ${fqdn} \\
         playbooks/ssh.yaml playbooks/k3s.yaml
EOF

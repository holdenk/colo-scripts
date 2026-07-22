#!/usr/bin/env bash
# make-jetson-image.sh -- build a ready-to-onboard Jetson Nano SD-card image.
#
# NVIDIA's JetPack SD image ships the interactive "oem-config" first-boot wizard
# (user/keyboard/locale prompts on an attached monitor), which is a non-starter
# for a headless colo node. This script takes that stock image and bakes in a
# self-removing first-boot service so the Nano instead comes up on the network
# with:
#   * its hostname set (under COLO_DOMAIN, default local.pigscanfly.ca)
#   * the colo admins (holden, warrick) created with passwordless sudo and their
#     GitHub SSH keys installed
#   * ssh enabled, and oem-config masked so nothing blocks on a console
#
# That matches what playbooks/ssh.yaml + playbooks/k3s.yaml (the "arm-gpus"
# group) expect, so once it is up you add it to hosts.yaml and run the usual
# Ansible flow. The keys are baked in at build time, so no monitor/keyboard and
# no first-boot internet are needed just to log in.
#
# Because the seed files are dropped into the rootfs (no chroot / qemu), the
# host doing the build stays simple; the account creation itself runs natively
# on the Nano at first boot.
#
# Design note: the image only has to get the operator far enough for Ansible to
# connect; playbooks/ssh.yaml distributes every admin's keys afterward. The
# intended direction is therefore to bake only the operator's own key here and
# let ssh.yaml own admin access as the single source of truth -- see the
# COLO_ADMINS design-decision note in lib/common.sh.
#
# NOTE: this targets the Jetson *Nano Developer Kit* SD-card image. Production
# modules (eMMC) are flashed with NVIDIA's SDK Manager / flash.sh instead; the
# oem-config service names can also drift between JetPack releases, so
# --oem-config-service is configurable.
#
# Examples:
#   ./make-jetson-image.sh --hostname nvmini5 --image ~/Downloads/sd-blob.img
#   ./make-jetson-image.sh --hostname nvmini5 --image-url <jetpack-sd.zip> --device /dev/sdX
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CACHE_DIR="${COLO_IMAGE_CACHE:-$SCRIPT_DIR/.cache}"

hostname=""
output=""
device=""
base_image=""
image_url=""
# systemd units for the interactive first-boot wizard, masked so the Nano boots
# straight through. Space-separated; override for other JetPack releases.
oem_services="nv-oem-config.service nvfb-early.service nvfb.service oem-config.service"

usage() {
  cat >&2 <<EOF
Usage: $0 --hostname NAME (--image FILE | --image-url URL) [options]

  --hostname NAME       hostname for the new Jetson (bare name is suffixed with
                        .$COLO_DOMAIN; pass an FQDN to override)
  --image FILE          already-downloaded/decompressed JetPack SD .img
  --image-url URL       JetPack SD image to download (.img / .zip / .xz)
  --output FILE         write the customized image here
                        (default: ./jetson-<hostname>.img)
  --device /dev/sdX     after building, dd the image onto this block device
                        (DESTRUCTIVE -- prompts first)
  --oem-config-service "u1 u2"
                        space-separated systemd units to mask so the console
                        wizard never runs (default: $oem_services)
  -h, --help            show this help

You must supply the base image with --image or --image-url; NVIDIA requires a
login to download JetPack, so there is no baked-in default URL.
EOF
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)            hostname="${2:?}"; shift 2 ;;
    --output)              output="${2:?}"; shift 2 ;;
    --device)              device="${2:?}"; shift 2 ;;
    --image)               base_image="${2:?}"; shift 2 ;;
    --image-url)           image_url="${2:?}"; shift 2 ;;
    --oem-config-service)  oem_services="${2:?}"; shift 2 ;;
    -h|--help)             usage 0 ;;
    *)                     warn "unknown argument: $1"; usage ;;
  esac
done

[[ -n "$hostname" ]] || { warn "--hostname is required"; usage; }
[[ -n "$base_image" || -n "$image_url" ]] || { warn "provide --image or --image-url"; usage; }

require_cmds curl losetup mount umount blkid blockdev

fqdn="$(fully_qualify "$hostname")"
short="${fqdn%%.*}"
output="${output:-jetson-${short}.img}"

# 1. Bake the admins' keys in now so the node needs no internet just to log
#    in. Each admin gets only their own keys, and every admin must resolve --
#    a partial set would bake an image some admins can't reach.
info "fetching admin SSH keys"
declare -A admin_keys=()
for entry in "${COLO_ADMINS[@]}"; do
  user="${entry%%:*}"; gh="${entry##*:}"
  admin_keys[$user]="$(github_keys "$gh")" \
    || die "could not fetch SSH keys for github user '$gh' (needed for '$user')"
done

# 2. Stage a private, re-runnable copy of the base image.
if [[ -n "$base_image" ]]; then
  [[ -f "$base_image" ]] || die "--image not found: $base_image"
  src_img="$base_image"
else
  src_img="$(resolve_base_image "$image_url" "$CACHE_DIR")"
fi

info "staging base image -> $output"
cp --reflink=auto "$src_img" "$output"

# 3. Mount the rootfs (largest partition -- APP) and drop in the seed files.
loopdev=""
mnt=""
cleanup() {
  [[ -n "$mnt" && -d "$mnt" ]] && { as_root umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
  [[ -n "$loopdev" ]] && as_root losetup -d "$loopdev" 2>/dev/null || true
}
trap cleanup EXIT

loopdev="$(as_root losetup -Pf --show "$output")"
as_root partprobe "$loopdev" 2>/dev/null || true

root_part="$(largest_partition "$loopdev")" || die "could not find a rootfs partition"
fstype="$(as_root blkid -o value -s TYPE "$root_part" 2>/dev/null || true)"
[[ "$fstype" == ext* ]] || warn "rootfs $root_part has unexpected fstype '$fstype'"
log "rootfs partition: $root_part ($fstype)"

mnt="$(mktemp -d)"
as_root mount "$root_part" "$mnt"

# 3a. Seed data (hostname, admin list, per-admin keys) consumed by the
#     first-boot script. Keeping the data out of the script means the script
#     below is completely static -- no build-time expansion to get wrong, and
#     each admin's authorized_keys holds only that admin's keys.
info "installing first-boot onboarding service for $fqdn"
seed_dir="$mnt/usr/local/share/colo-onboard"
as_root install -d -m 0755 "$seed_dir" "$seed_dir/keys"
as_root tee "$seed_dir/config" >/dev/null <<EOF
HOSTNAME_FQDN="$fqdn"
HOSTNAME_SHORT="$short"
EOF
{
  for entry in "${COLO_ADMINS[@]}"; do printf '%s\n' "${entry%%:*}"; done
} | as_root tee "$seed_dir/admins" >/dev/null
for entry in "${COLO_ADMINS[@]}"; do
  user="${entry%%:*}"
  printf '%s\n' "${admin_keys[$user]}" \
    | as_root tee "$seed_dir/keys/$user.authorized_keys" >/dev/null
done

# 3b. First-boot script (static; runs natively on the Nano).
as_root install -d -m 0755 "$mnt/usr/local/sbin"
as_root tee "$mnt/usr/local/sbin/colo-firstboot.sh" >/dev/null <<'FIRSTBOOT'
#!/bin/bash
# Managed by onboarding/make-jetson-image.sh -- runs once at first boot to make
# this Jetson reachable for Ansible, then disables itself. All inputs come
# from /usr/local/share/colo-onboard (written at image build time).
set -eu

CONF_DIR=/usr/local/share/colo-onboard
# shellcheck source=/dev/null
. "$CONF_DIR/config"

hostnamectl set-hostname "$HOSTNAME_SHORT" || echo "$HOSTNAME_SHORT" >/etc/hostname
if ! grep -q "$HOSTNAME_FQDN" /etc/hosts 2>/dev/null; then
  printf '127.0.1.1\t%s %s\n' "$HOSTNAME_FQDN" "$HOSTNAME_SHORT" >>/etc/hosts
fi

while IFS= read -r user; do
  [ -n "$user" ] || continue
  id -u "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
  usermod -aG sudo "$user" || true
  group="$(id -gn "$user")"
  install -d -m 0700 -o "$user" -g "$group" "/home/$user/.ssh"
  install -m 0600 -o "$user" -g "$group" \
    "$CONF_DIR/keys/$user.authorized_keys" "/home/$user/.ssh/authorized_keys"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"/etc/sudoers.d/90-colo-$user"
  chmod 0440 "/etc/sudoers.d/90-colo-$user"
done <"$CONF_DIR/admins"

systemctl enable --now ssh 2>/dev/null || true

touch /etc/colo-onboarded
systemctl disable colo-onboard.service 2>/dev/null || true
exit 0
FIRSTBOOT
as_root chmod 0755 "$mnt/usr/local/sbin/colo-firstboot.sh"

# 3c. systemd unit + enable symlink (so we don't need systemctl on the host).
as_root tee "$mnt/etc/systemd/system/colo-onboard.service" >/dev/null <<'EOF'
[Unit]
Description=Colo first-boot onboarding (users, keys, hostname, ssh)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/etc/colo-onboarded

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/colo-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
as_root install -d -m 0755 "$mnt/etc/systemd/system/multi-user.target.wants"
as_root ln -sf /etc/systemd/system/colo-onboard.service \
  "$mnt/etc/systemd/system/multi-user.target.wants/colo-onboard.service"

# 3d. Mask the interactive oem-config wizard so it never blocks the console.
# Unit names drift between JetPack releases, so mask what actually exists in
# the image (masking a nonexistent unit is a silent no-op) plus any
# nv-oem-config* frontends found by glob, and say what happened either way.
masked=()
for unit in $oem_services; do
  for dir in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
    if [[ -e "$mnt/$dir/$unit" ]]; then
      as_root ln -sf /dev/null "$mnt/etc/systemd/system/$unit"
      masked+=("$unit")
      break
    fi
  done
done
for f in "$mnt"/lib/systemd/system/nv-oem-config*.service \
         "$mnt"/usr/lib/systemd/system/nv-oem-config*.service; do
  [[ -e "$f" ]] || continue
  unit="$(basename "$f")"
  [[ " ${masked[*]} " == *" $unit "* ]] && continue
  as_root ln -sf /dev/null "$mnt/etc/systemd/system/$unit"
  masked+=("$unit")
done
if [[ ${#masked[@]} -gt 0 ]]; then
  log "masked first-boot wizard units: ${masked[*]}"
else
  warn "no oem-config/nvfb units found in this image -- relying only on the"
  warn "default.target override to skip the wizard (see --oem-config-service)"
fi
# Boot straight to multi-user rather than the oem-config target.
as_root ln -sf /lib/systemd/system/multi-user.target "$mnt/etc/systemd/system/default.target"

as_root sync
info "image ready: $output"

# 4. Optionally flash it onto an SD card / USB device.
if [[ -n "$device" ]]; then
  [[ -b "$device" ]] || die "--device is not a block device: $device"
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
  1. Boot the Jetson from this image on the colo network (no monitor needed).
  2. Add '${fqdn}:' under the 'arm-gpus' group in hosts.yaml.
  3. Onboard it with Ansible, e.g.:
       ansible-playbook -i hosts.yaml --vault-id dev@secret \\
         --extra-vars @passwd.yml --limit ${fqdn} \\
         playbooks/ssh.yaml playbooks/k3s.yaml
EOF

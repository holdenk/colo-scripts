# shellcheck shell=bash
# Shared helpers for the colo onboarding scripts (make-pi-image.sh,
# make-jetson-image.sh, setup-turing-pi.sh).
#
# This file is meant to be *sourced*, not executed. It intentionally sticks to
# tools you already have on a stock Ubuntu/Debian workstation used for flashing
# SD cards, so the onboarding scripts stay easy to run from a laptop.

# --- shared defaults --------------------------------------------------------

# DNS domain new nodes live under. Read from playbooks/k3s-vars.yaml (the
# single source of truth the k3sup joins use) so the two can't drift; the
# literal is only a fallback for running a script copied out of the repo.
if [[ -z "${COLO_DOMAIN:-}" ]]; then
  COLO_DOMAIN="$(sed -n 's/^domain:[[:space:]]*//p' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/playbooks/k3s-vars.yaml" \
    2>/dev/null | head -n1)"
fi
: "${COLO_DOMAIN:=local.pigscanfly.ca}"

# DESIGN DECISION: onboarding images carry only the key of the *operator*
# running the setup script -- NOT the full admin roster.
#
# An image only has to get the operator onto the box far enough for Ansible to
# connect; playbooks/ssh.yaml then creates every admin (holden, warrick, ...)
# with their GitHub keys. Keeping admin keys solely in ssh.yaml means there is
# ONE source of truth for who has access -- there is deliberately no admin list
# in these scripts to drift out of sync with the playbook. The operator's own
# public key is a local file they already hold the private half of, so baking
# it needs no network and no GitHub fetch at build time.

# --- logging ----------------------------------------------------------------

if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'
  _c_dim=$'\033[2m'; _c_rst=$'\033[0m'
else
  _c_red=''; _c_yel=''; _c_grn=''; _c_dim=''; _c_rst=''
fi

log()  { printf '%s[%s]%s %s\n' "$_c_dim" "$(date +%H:%M:%S)" "$_c_rst" "$*" >&2; }
info() { printf '%s==>%s %s\n' "$_c_grn" "$_c_rst" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$_c_yel" "$_c_rst" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_rst" "$*" >&2; exit 1; }

# --- small utilities --------------------------------------------------------

# require_cmds cmd1 cmd2 ...  -- die if any are missing from PATH.
require_cmds() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required command(s): ${missing[*]}"
}

# as_root cmd ...  -- run a command with root privileges, using sudo only when
# we are not already root.
as_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# fully_qualify <name>  -- echo "<name>.<domain>" unless it already looks
# fully-qualified (contains a dot).
fully_qualify() {
  local name="$1"
  if [[ "$name" == *.* ]]; then
    printf '%s\n' "$name"
  else
    printf '%s.%s\n' "$name" "$COLO_DOMAIN"
  fi
}

# operator_user  -- the human running the setup script. Unwraps sudo so that
# `sudo ./make-pi-image.sh` still resolves to the invoking user, not root.
operator_user() {
  printf '%s\n' "${SUDO_USER:-$(id -un)}"
}

# operator_home  -- home directory of operator_user (via passwd, $HOME fallback).
operator_home() {
  local home
  home="$(getent passwd "$(operator_user)" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] && printf '%s\n' "$home" || printf '%s\n' "$HOME"
}

# default_pubkey  -- path to the operator's SSH public key, or fail. Honors
# $SSH_PUBKEY, else prefers a standard key type, else the first ~/.ssh/*.pub.
default_pubkey() {
  if [[ -n "${SSH_PUBKEY:-}" ]]; then
    printf '%s\n' "$SSH_PUBKEY"
    return 0
  fi
  local home k
  home="$(operator_home)"
  for k in id_ed25519 id_ecdsa id_rsa; do
    if [[ -f "$home/.ssh/$k.pub" ]]; then
      printf '%s\n' "$home/.ssh/$k.pub"
      return 0
    fi
  done
  # Fall back to the first *.pub; if the glob doesn't match it stays literal,
  # so the -f test below fails and we report "none found".
  local -a pubs=("$home"/.ssh/*.pub)
  [[ -f "${pubs[0]}" ]] || return 1
  printf '%s\n' "${pubs[0]}"
}

# emit_cloud_init_bootstrap_user <user> <pubkey-file>  -- print a cloud-init
# `users:` block for a single bootstrap user carrying the operator's key(s).
emit_cloud_init_bootstrap_user() {
  local user="$1" keyfile="$2" line
  printf 'users:\n'
  printf '  - name: %s\n' "$user"
  printf '    groups: [adm, sudo]\n'
  printf '    shell: /bin/bash\n'
  printf '    lock_passwd: true\n'
  printf '    sudo: "ALL=(ALL) NOPASSWD:ALL"\n'
  printf '    ssh_authorized_keys:\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '      - "%s"\n' "$line"
  done <"$keyfile"
}

# resolve_bootstrap_key <pubkey-arg>  -- echo a validated pubkey path, dying
# with actionable advice if none is found. Empty arg => auto-detect.
resolve_bootstrap_key() {
  local pubkey="$1"
  if [[ -z "$pubkey" ]]; then
    pubkey="$(default_pubkey)" || die \
      "no SSH public key found for operator '$(operator_user)' in $(operator_home)/.ssh; pass --pubkey FILE or run ssh-keygen"
  fi
  [[ -f "$pubkey" ]] || die "--pubkey not found: $pubkey"
  local first
  IFS= read -r first <"$pubkey" || true
  case "$first" in
    ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
    *) die "--pubkey does not look like an SSH public key: $pubkey" ;;
  esac
  printf '%s\n' "$pubkey"
}

# resolve_base_image <url> <cache_dir>  -- ensure the (possibly .xz/.zip
# compressed) image at <url> is downloaded and decompressed under <cache_dir>,
# echoing the path to the ready-to-use .img on stdout.
resolve_base_image() {
  local url="$1" cache="$2"
  local fname img
  fname="$(basename "$url")"
  mkdir -p "$cache"

  local archive="$cache/$fname"
  if [[ -f "$archive" ]]; then
    log "using cached download $archive"
  else
    info "downloading $url"
    curl -fL --retry 3 --retry-delay 2 -o "$archive.part" "$url" \
      || die "download failed: $url"
    mv "$archive.part" "$archive"
  fi

  case "$fname" in
    *.img.xz|*.xz)
      require_cmds xz
      img="$cache/${fname%.xz}"
      if [[ ! -f "$img" ]]; then
        info "decompressing $fname"
        if ! xz -dkc "$archive" >"$img.part"; then
          rm -f "$img.part"
          die "xz decompression of $fname failed (corrupt download or disk full?)"
        fi
        mv "$img.part" "$img"
      fi
      ;;
    *.img.zip|*.zip)
      require_cmds unzip
      # Ask the zip for its .img member name -- vendor zips (e.g. JetPack's
      # sd-blob-b01.img) rarely match the archive's own filename, and unzip
      # restores archived mtimes so no -newer heuristic can find it either.
      local member
      member="$(unzip -Z1 "$archive" 2>/dev/null | grep -i '\.img$' | head -n1 || true)"
      [[ -n "$member" ]] || die "no .img member inside $fname"
      img="$cache/$(basename "$member")"
      if [[ ! -f "$img" ]]; then
        info "unzipping $member from $fname"
        ( cd "$cache" && unzip -o "$fname" "$member" >/dev/null ) \
          || die "unzip of $member from $fname failed"
        # Flatten a path-carrying member down into the cache root.
        if [[ "$member" != "$(basename "$member")" && -f "$cache/$member" ]]; then
          mv "$cache/$member" "$img"
        fi
        [[ -f "$img" ]] || die "extraction of $member from $fname failed"
      fi
      ;;
    *.img)
      img="$archive"
      ;;
    *)
      die "don't know how to decompress '$fname' (expected .img, .xz or .zip)"
      ;;
  esac

  printf '%s\n' "$img"
}

# first_partition_of_type <loopdev> <fstype>  -- echo the first partition of
# the given loop device whose filesystem TYPE matches, or return non-zero.
first_partition_of_type() {
  local loopdev="$1" want="$2" part fstype
  for part in "${loopdev}p"[0-9]*; do
    [[ -b "$part" ]] || continue
    fstype="$(as_root blkid -o value -s TYPE "$part" 2>/dev/null || true)"
    if [[ "$fstype" == "$want" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done
  return 1
}

# largest_partition <loopdev>  -- echo the partition with the most sectors
# (used to find the rootfs on images with many small firmware partitions).
largest_partition() {
  local loopdev="$1" part best="" best_sz=0 sz
  for part in "${loopdev}p"[0-9]*; do
    [[ -b "$part" ]] || continue
    sz="$(as_root blockdev --getsz "$part" 2>/dev/null || echo 0)"
    if (( sz > best_sz )); then best_sz="$sz"; best="$part"; fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

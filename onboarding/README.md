# Node onboarding scripts

Helpers for turning a blank Raspberry Pi / Jetson / Turing Pi node into one that
is reachable over SSH so the existing Ansible playbooks (`playbooks/ssh.yaml`,
`playbooks/k3s.yaml`, …) can take over.

The goal of every script here is the same "onboarded" end state — a node
`playbooks/ssh.yaml` can connect to:

* hostname set under `local.pigscanfly.ca` (override with `COLO_DOMAIN`)
* a single **bootstrap user** — by default the operator running the script —
  created with passwordless `sudo`
* the **operator's own SSH public key** baked in (their `~/.ssh/*.pub`, or
  `$SSH_PUBKEY`), so the node is reachable the instant it boots — no monitor,
  keyboard, GitHub fetch, or first-boot internet needed
* `ssh` enabled

**Design decision — the images carry only the operator's key.** An image just
has to get the operator far enough for Ansible to connect; `playbooks/ssh.yaml`
then creates every admin (`holden`, `warrick`, …) with their GitHub keys. That
keeps `ssh.yaml` the *single source of truth* for admin access — there is no
admin list in these scripts to drift out of sync with the playbook. Override
the bootstrap user with `--user` and the key with `--pubkey`.

After a node is up you add it to `hosts.yaml` and run the normal flow (connect
as the bootstrap user; `ssh.yaml` distributes everyone's keys):

```sh
ansible-playbook -i hosts.yaml --vault-id dev@secret --extra-vars @passwd.yml \
  --limit <fqdn> -u <bootstrap-user> playbooks/ssh.yaml playbooks/k3s.yaml
```

## Scripts

| Script | Purpose | hosts.yaml group |
| --- | --- | --- |
| `make-pi-image.sh` | Customize the Ubuntu Server arm64 image for a Raspberry Pi | `pis` |
| `make-jetson-image.sh` | Customize a JetPack SD image for a Jetson Nano | `arm-gpus` |
| `setup-turing-pi.sh` | Power / flash / discover Turing Pi 2 node slots via the BMC | `pis` / `arm-gpus` |

Shared logic (logging, operator-key resolution, image mounting) lives in
`lib/common.sh`.

### `make-pi-image.sh`

Bakes a cloud-init seed into the stock Ubuntu Server Raspberry Pi image.

```sh
# DHCP, default output ./pi-rpi3.img; bootstrap user = you, key = your ~/.ssh
./make-pi-image.sh --hostname rpi3

# explicit bootstrap user and key
./make-pi-image.sh --hostname rpi3 --user holden --pubkey ~/.ssh/id_ed25519.pub

# static IP and write straight to an SD card
./make-pi-image.sh --hostname erpi4 --ip 10.0.0.54/24 --gateway 10.0.0.1 \
  --device /dev/sdX
```

If the default Ubuntu point-release URL ages out, pass `--image-url` (or a
pre-downloaded image with `--image`).

### `make-jetson-image.sh`

NVIDIA's JetPack SD image ships the interactive `oem-config` wizard, which is
useless for a headless node. This script drops in a self-removing first-boot
service (bootstrap user, operator key, hostname, ssh) and masks `oem-config` so
the Nano boots straight onto the network.

```sh
# JetPack requires a login to download, so you supply the base image
./make-jetson-image.sh --hostname nvmini5 --image ~/Downloads/sd-blob.img

# explicit bootstrap user and key
./make-jetson-image.sh --hostname nvmini5 --image ~/Downloads/sd-blob.img \
  --user holden --pubkey ~/.ssh/id_ed25519.pub
```

Targets the **Jetson Nano Developer Kit** SD image. Production (eMMC) modules are
flashed with NVIDIA's SDK Manager / `flash.sh`; the `oem-config` service names
can vary between JetPack releases, so `--oem-config-service` is configurable.

### `setup-turing-pi.sh`

Drives a Turing Pi 2 BMC (via the [`tpi`](https://github.com/turing-machines/tpi)
CLI, falling back to the BMC REST API) to power, flash, and *discover* node
slots. It is "dynamic" in that it acts on whatever slots you point it at, powers
them on, and then finds out which ones actually answer — empty slots are just
reported, not treated as errors.

```sh
# power on all four slots and wait for them to come up as tpi-node1..4
./setup-turing-pi.sh --host turingpi.local --wait --node-prefix tpi-node

# flash a Pi image onto slot 2, power it, wait for it as rpi3
./setup-turing-pi.sh --host turingpi.local \
  --flash 2=pi-rpi3.img --nodes 2 --wait --node-host 2=rpi3

# just report what the board sees
./setup-turing-pi.sh --host turingpi.local --power status
```

BMC connection comes from `--host/--user/--pass` or `TPI_HOST/TPI_USER/TPI_PASS`.
With `--wait` it reports a slot `ready` only once SSH **key auth** succeeds as
the bootstrap user (the operator, or `--probe-user`); a slot whose port 22 is
open but not yet authenticating (first-boot still running) is listed separately
as `port open`.

## Typical Turing Pi flow

```sh
# 1. build images for the modules you are about to seat
./make-pi-image.sh --hostname rpi3
./make-jetson-image.sh --hostname nvmini5 --image ~/Downloads/sd-blob.img

# 2. flash + power + discover the slots
./setup-turing-pi.sh --host turingpi.local \
  --flash 1=pi-rpi3.img --node-host 1=rpi3 \
  --flash 3=jetson-nvmini5.img --node-host 3=nvmini5 \
  --wait

# 3. add the nodes that came up to hosts.yaml, then onboard with Ansible
#    (connect as the bootstrap user; ssh.yaml then installs everyone's keys)
ansible-playbook -i hosts.yaml --vault-id dev@secret --extra-vars @passwd.yml \
  --limit rpi3,nvmini5 -u "$(id -un)" playbooks/ssh.yaml playbooks/k3s.yaml
```

## Requirements

Run these from an Ubuntu/Debian workstation (the one you use to flash SD cards):

* `curl`, `xz-utils`, `unzip` — download/decompress base images
* `util-linux` (`losetup`, `blkid`, `blockdev`), `mount` — image customization
  (the loop-mount steps use `sudo` when you are not already root)
* `tpi` — only for `setup-turing-pi.sh` flashing; power/status fall back to the
  BMC REST API via `curl`. `--wait` additionally needs `timeout` (coreutils)
  and, for the key-auth check, an `ssh` client

The bootstrap key comes from your own `~/.ssh` (or `$SSH_PUBKEY` / `--pubkey`),
so image builds need **no network for keys** — only to download the base image.

Downloaded base images are cached under `onboarding/.cache` (override with
`COLO_IMAGE_CACHE`); that directory is git-ignored.

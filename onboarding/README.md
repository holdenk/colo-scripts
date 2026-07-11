# Node onboarding scripts

Helpers for turning a blank Raspberry Pi / Jetson / Turing Pi node into one that
is reachable over SSH so the existing Ansible playbooks (`playbooks/ssh.yaml`,
`playbooks/k3s.yaml`, …) can take over.

The goal of every script here is the same "onboarded" end state, matching what
`playbooks/ssh.yaml` expects:

* hostname set under `local.pigscanfly.ca` (override with `COLO_DOMAIN`)
* the colo admins (`holden`, `warrick`) created with passwordless `sudo`
* their GitHub SSH keys installed (pulled from `github.com/<user>.keys`, same
  source `ssh.yaml` uses) and **baked into the image at build time**, so a node
  is reachable the instant it boots — no monitor, keyboard, or first-boot
  internet needed just to log in
* `ssh` enabled

After a node is up you add it to `hosts.yaml` and run the normal flow:

```sh
ansible-playbook -i hosts.yaml --vault-id dev@secret --extra-vars @passwd.yml \
  --limit <fqdn> playbooks/ssh.yaml playbooks/k3s.yaml
```

## Scripts

| Script | Purpose | hosts.yaml group |
| --- | --- | --- |
| `make-pi-image.sh` | Customize the Ubuntu Server arm64 image for a Raspberry Pi | `pis` |
| `make-jetson-image.sh` | Customize a JetPack SD image for a Jetson Nano | `arm-gpus` |
| `setup-turing-pi.sh` | Power / flash / discover Turing Pi 2 node slots via the BMC | `pis` / `arm-gpus` |

Shared logic (logging, key fetching, image mounting) lives in `lib/common.sh`.

### `make-pi-image.sh`

Bakes a cloud-init seed into the stock Ubuntu Server Raspberry Pi image.

```sh
# DHCP, default output ./pi-rpi3.img
./make-pi-image.sh --hostname rpi3

# static IP and write straight to an SD card
./make-pi-image.sh --hostname erpi4 --ip 10.0.0.54/24 --gateway 10.0.0.1 \
  --device /dev/sdX
```

If the default Ubuntu point-release URL ages out, pass `--image-url` (or a
pre-downloaded image with `--image`).

### `make-jetson-image.sh`

NVIDIA's JetPack SD image ships the interactive `oem-config` wizard, which is
useless for a headless node. This script drops in a self-removing first-boot
service (users, keys, hostname, ssh) and masks `oem-config` so the Nano boots
straight onto the network.

```sh
# JetPack requires a login to download, so you supply the base image
./make-jetson-image.sh --hostname nvmini5 --image ~/Downloads/sd-blob.img
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
ansible-playbook -i hosts.yaml --vault-id dev@secret --extra-vars @passwd.yml \
  --limit rpi3,nvmini5 playbooks/ssh.yaml playbooks/k3s.yaml
```

## Requirements

Run these from an Ubuntu/Debian workstation (the one you use to flash SD cards):

* `curl`, `xz-utils`, `unzip` — download/decompress base images and fetch keys
* `util-linux` (`losetup`, `blkid`, `blockdev`), `mount` — image customization
  (the loop-mount steps use `sudo` when you are not already root)
* `tpi` — only for `setup-turing-pi.sh` flashing; power/status fall back to the
  BMC REST API via `curl`

Downloaded base images are cached under `onboarding/.cache` (override with
`COLO_IMAGE_CACHE`); that directory is git-ignored.

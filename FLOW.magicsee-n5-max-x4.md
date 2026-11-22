# Magicsee N5 Max X4 — Flow

**English** | [Tiếng Việt](FLOW.magicsee-n5-max-x4.vi.md)

[← Main README](README.md) · [Box README](README.magicsee-n5-max-x4.md)

Three separate flows:

| Flow | When | Output |
|---|---|---|
| **A. Kernel bundle** | Whenever ophub `kernel_s905x4` has a new version, or a driver/DTB changes | Release `kernel_magicsee/<kver>.tar.gz` |
| **B. Image** | When a new image is needed (new Armbian/Debian, rootfs changes) | `Armbian_*_magicsee-n5-max-x4_*.img.xz` |
| **C. Kernel upgrade on the box** | After a new bundle is published | Box runs the new kernel, drivers match it |

The box **never builds** drivers. Everything is built in WSL.

---

## 0. Environment (WSL Debian)

```bash
# Clone inside the WSL filesystem, not from /mnt/d (core.symlinks=false on Windows breaks symlinks)
git clone -b magicsee-n5-max-x4/26.11.0 git@github.com:thanhnhu/amlogic-s9xxx-armbian.git ~/amlogic-armbian
git clone git@github.com:thanhnhu/wifi-amlogic-w1.git       ~/src/wifi-amlogic-w1
git clone git@github.com:thanhnhu/aml_bt.git                ~/src/aml_bt
git clone https://github.com/jefflessard/tm16xx-display.git ~/src/tm16xx-display

sudo apt-get install -y $(curl -fsSL https://ophub.org/ubuntu2604-build-armbian-depends)
sudo apt-get install -y device-tree-compiler gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev kmod \
                        qemu-user-static binfmt-support
```

---

## A. Kernel bundle `kernel_magicsee` (`magicsee/build-kernel-bundle.sh`)

```bash
./magicsee/build-kernel-bundle.sh 6.18.63          # -> ~/magicsee-out/6.18.63.tar.gz
```

Environment variables: `WIFI_SRC`, `BT_SRC`, `TM16XX_SRC` (default `~/src/...`), `TM16XX_REF` (pinned commit), `OUT`, `WORK`. The script uploads nothing.

What it does:

1. Downloads `https://github.com/ophub/kernel/releases/download/kernel_s905x4/<kver>.tar.gz` and checks its `sha256sums`.
2. Unpacks `header-<kver>-meson64.tar.gz` and runs `olddefconfig` + `scripts` for `ARCH=arm64`. The ophub header package carries no host tools (`fixdep`, `modpost`).
3. Cross-compiles against those headers:
   - `wifi-amlogic-w1/project_w1` → `aml_sdio.ko`, `vlsicomm.ko`
   - `aml_bt` → `sdio_bt.ko`; `drivers/bluetooth` of the exact `<kver>` from kernel.org + `kernel/hci_aml-w155s1.patch` → `hci_uart.ko`
   - `tm16xx-display` → `tm16xx.ko`, `tm16xx_i2c.ko`

   Build-time fixes live in `magicsee/patches/<repo>/*.patch` and are applied to a copy, so the driver repos stay untouched.
   For example `wifi-amlogic-w1/0001-rename-michael_mic.patch`: 6.18.63 added a global `michael_mic()` that clashes with the driver's static helper.
4. Unpacks `modules-<kver>-meson64.tar.gz`, replaces the same-named modules in place (`kernel/drivers/net/wireless/amlogic/`, `kernel/drivers/bluetooth/`), adds the new ones under `kernel/drivers/auxdisplay/`, and runs `depmod -b … -F System.map` on the host (depmod is architecture independent).
5. Compiles `magicsee/dts/meson-sc2-magicsee-n5-max-x4.dts` and adds it to `dtb-amlogic-<kver>-meson64.tar.gz`.
6. Regenerates `sha256sums`, writes `BUILDINFO` (source commits) and packs `<kver>.tar.gz`.

Every new module is checked: `modinfo -F vermagic` must equal `<kver>-meson64`, otherwise the script stops.

Publish (manual step):

```bash
gh release upload kernel_magicsee ~/magicsee-out/<kver>.tar.gz --repo thanhnhu/amlogic-s9xxx-armbian --clobber
```

Or use it locally without publishing: unpack it to `build-armbian/kernel/magicsee/<kver>/`, and `rebuild` will take the kernel from there.

---

## B. Image

### B1. Base image

From the ophub release `Armbian_trixie_arm64_server_<YYYY.MM>` (file `*-trunk_*.img.gz`).

```bash
mkdir -p ~/amlogic-armbian/build/output/images
gzip -dc ~/armbian-base/Armbian_26.11.0-trunk_trixie_arm64_6.18.64.img.gz \
  > ~/amlogic-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.64.img
```

The base image has a single ext4 partition (starting at sector 8192). It already has `dkms`/`gcc`/`network-manager`/`wpasupplicant`/`iw`, but **not** `bluez` or `ir-keytable`.

### B2. Rebuild

```bash
cd ~/amlogic-armbian
# Before kernel_magicsee exists: column 9 = s905x4/6.18.y (ophub kernel, WiFi/BT/panel drivers not right)
# Once kernel_magicsee exists:   column 9 = magicsee/6.18.y
sudo ./rebuild -b magicsee-n5-max-x4 -k 6.18.y -r thanhnhu/amlogic-s9xxx-armbian
```

`rebuild` downloads the kernel from `<repo>/releases/download/kernel_<tag>/<kver>.tar.gz`, plus `ophub/u-boot` and `ophub/firmware` (`aml/w1_bt_fw_uart.bin`, `aml_wifi_*`).
It writes `KERNEL_REPO` and `KERNEL_TAGS` to `/etc/ophub-release`, so `armbian-update` on the box uses the right repository.

### B3. Image post-processing (`magicsee/build-image-post.sh`)

```bash
sudo ./magicsee/build-image-post.sh build/output/images/Armbian_*_magicsee-n5-max-x4_*.img.gz
```

It mounts the image and works in a chroot through `qemu-aarch64-static`:

1. `apt-get install --no-install-recommends bluez ir-keytable`
2. `apt-mark hold` on the installed `linux-image-*` / `linux-dtb-*` / `linux-u-boot-*` packages of the base image
3. `/etc/rc_keymaps/magicsee.toml` (from `amlogic-remote-1`, `0xf709`) plus a `meson-ir` line in `/etc/rc_maps.cfg`; `ir-keytable`'s udev rule loads it when `rc0` appears
4. Front-panel service (clock/IP): jefflessard's `display-service` + `display.service`
5. Not yet: `wlan-5g-warmup` (from the wifi repo)
5. `apt-get clean`, remove `qemu-aarch64-static`, unmount, compress to `.img.xz` with a `sha256`

### B4. DTB in the repo

`platform-files/amlogic/bootfs/dtb/amlogic/meson-sc2-magicsee-n5-max-x4.dtb` must be rebuilt after every DTS change:

```bash
cd ~/amlogic-armbian/build-armbian/armbian-files
dtc -I dts -O dtb \
  -o platform-files/amlogic/bootfs/dtb/amlogic/meson-sc2-magicsee-n5-max-x4.dtb \
  ~/amlogic-armbian/magicsee/dts/meson-sc2-magicsee-n5-max-x4.dts
```

dtc prints `clocks_property` / `unit_address` warnings. That is normal for a DTS decompiled from a DTB.

---

## C. Kernel upgrade on the box

```bash
armbian-update              # uses KERNEL_REPO / KERNEL_TAGS from /etc/ophub-release
armbian-update -k 6.18.70   # or a specific version
```

Kernel, modules (with our drivers) and DTB are replaced **together**, so they never drift apart.
Do not upgrade the kernel with `apt`. The Armbian kernel package is already on hold.

---

## D. Flash and test (USB first, leave the eMMC alone)

1. Write the image to a USB stick (BalenaEtcher / `dd`). SD cards do not boot on this box.
2. Plug in the stick, hold the reset button in the AV jack, power on, keep holding for about 7 seconds.
3. Check:

```bash
cat /proc/device-tree/model                            # Magicsee N5 Max X4
modinfo -F vermagic vlsicomm hci_uart tm16xx           # same kernel as uname -r
ip -br link; iw dev                                    # eth0, wlan0
hciconfig; dmesg | grep -i fw_version                  # hci0 UP, fw_version present
ls /sys/class/rc/rc0; ir-keytable -t                   # remote key presses show scancodes/keys
ls /sys/class/leds                                     # power, *::colon, *::usb, ...
cat /sys/class/thermal/thermal_zone*/temp
```

4. Install to eMMC (`armbian-install`) only once it is stable. Back up the current eMMC (devmfc Debian) first:
   `dd if=/dev/mmcblk1 bs=4M status=progress | gzip -1 > emmc_debian_backup.img.gz`

---

## E. Moving to a new version (branch)

```bash
git switch magicsee-n5-max-x4/26.11.0
git switch -c magicsee-n5-max-x4/<new-ver>
git fetch upstream && git rebase upstream/main
```

The old branch stays as it is, to rebuild old images when needed. After the rebase, re-check the `model_database.conf` format, the `release=` branch in `rebuild`, and the s905x4 row in `README.md`.

---

## F. Kernel 7 (later)

- SC2 is not in mainline Linux. `kernel_s905x4` is based on devmfc's patches (`devmfc/linux` is public up to `meson64-6.14`).
- Needed: a 7.x tree plus the SC2 patches (pinctrl, clk, pwrc, dwmac, mmc, `meson-s4-dw-hdmi`, `meson-s4-ir`), with a self-built kernel replacing step A1.
  Steps A2–A6 stay the same. Change column 9 of row 602 to `magicsee/7.x.y`.
- The drivers must be ported to the 7.x API. Keep the 6.18 bundle as a fallback.

# Magicsee N5 Max X4 — Armbian

**English** | [Tiếng Việt](README.magicsee-n5-max-x4.vi.md)

[← Main README](README.md) · [Build / flash / kernel upgrade flow](FLOW.magicsee-n5-max-x4.md)

Board support for the **Magicsee N5 Max X4** (Amlogic S905X4 / SC2), built on
[ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian).

| | |
|---|---|
| Model ID / Board | `602` / `magicsee-n5-max-x4` |
| BOOT_CONF | `boot.config` (devmfc bootscript, `box=magicseen5maxx4`) |
| Kernel | `kernel_magicsee` = ophub `kernel_s905x4` **plus** this box's drivers and DTB (see [Kernel bundle](#kernel-bundle)) |
| Branch | `magicsee-n5-max-x4/<armbian-version>`, e.g. `magicsee-n5-max-x4/26.11.0` |

---

## Approach

1. **All hardware is described in the box's DTB** (`meson-sc2-magicsee-n5-max-x4.dtb`): WiFi power, BT UART, IR, power LED, VFD, SD card detect.
   Nothing patches the DTB on the box, no overlays, no boot-time service pushing hardware settings.
2. **Drivers are built on the build host (WSL) and ship with the kernel.** The `kernel_magicsee` release is ophub `kernel_s905x4` plus our drivers (WiFi, BT, VFD) plus the DTB.
   The box **never compiles anything**. No DKMS: the box is too weak for it.
3. **Kernel upgrades go through `armbian-update`.** Kernel, modules and DTB are replaced together from `kernel_magicsee`, so the drivers always match the kernel.
   The Armbian kernel package left in dpkg is put on `apt-mark hold`.
4. **The image only adds the packages the hardware needs**: `bluez`, `ir-keytable`. No application packages.
5. **One branch per version**: `magicsee-n5-max-x4/<ver>`. Old branches are kept so old builds can be reproduced.

Details: [Kernel bundle](#kernel-bundle) · [FLOW](FLOW.magicsee-n5-max-x4.md).

---

## Hardware

| Component | Details |
|---|---|
| SoC | Amlogic S905X4 (SC2), 4× Cortex-A55, Mali-G31 |
| Reference board | `sc2_s905x4_ah212` (an X96 X4 clone, devmfc `box=x96x4`) |
| RAM / eMMC | 4 GB / 32 GB (`mmcblk1`) |
| Ethernet | 100 Mbit, internal PHY (`rmii`) |
| WiFi + BT | Amlogic **W1 / W155S1** (SDIO `8888:8888`), BT on UART `serial@fe080000` |
| Display | **FD6551** front panel, 2 wires, bit-banged I²C |
| IR | `remote_input_d5`, NEC protocol |
| Power LED | GPIO `0x28`, wired to the board directly, not through the panel controller |
| Buttons | Only the reset/update button in the AV jack, read by u-boot. Android's `gpio_keypad` and `adc_keypad` are both `disabled` |
| Audio | HDMI/SPDIF exist in Android, **not yet** in the mainline SC2 DTS |

### GPIO map

The Android DTB (phandle `0x1b`) and the Magicsee DTB (phandle `0x13`) use the same numbering. Pin names follow `dt-bindings/gpio/meson-sc2-gpio.h`.

| GPIO | Pin | Function | Node in the Magicsee DTB |
|---|---|---|---|
| `0x18` | | SD card detect | `sd@fe08a000 cd-gpios` |
| `0x23` (35) | GPIOD_6 | Panel clock | `i2c-display scl-gpios` |
| `0x24` (36) | GPIOD_7 | Panel data | `i2c-display sda-gpios` |
| `0x28` | | Power LED | `leds/led-power` (`default-state = "keep"`) |
| `0x38` | | WiFi power/reset | `sdio-pwrseq reset-gpios`, `aml_wifi power_on-gpios` |
| `0x39` | | WiFi host wake | `aml_wifi interrupt-gpios` |
| `0x43` | | BT enable | `serial@80000/bluetooth enable-gpios` |
| `0x45` | | BT host wake | `interrupts = <0x5f …>` via gpio-intc |

### Front panel (FD6551)

- Source: Android openvfd [`magicsee-n5-max-x4-vfd.conf`](https://github.com/arthur-liberman/vfd-configurations/blob/master/magicsee-n5-max-x4-vfd.conf):
  `clk=35`, `dat=36`, no STB, `display_type=0x01,0x00,0x00,0x06` (T95, FD6551).
- Driver: [jefflessard/tm16xx-display](https://github.com/jefflessard/tm16xx-display) (`tm16xx`, `tm16xx_i2c`), built out of tree. That repo already has [`devices/magicsee-n5-max-x4.dtso`](https://github.com/jefflessard/tm16xx-display/blob/main/devices/magicsee-n5-max-x4.dtso).
- Segment layout: bytes 1–4, bits `3 4 5 0 1 2 6`. Same as `map6` of the devmfc driver the box runs today.
- The box today (devmfc kernel 6.18.40) uses a `tm16xx` driver **built into the devmfc kernel**, compatible `devmfc,fd6551`. The ophub kernel does not have it.
- Mainline Linux (7.4) has no `tm16xx` either, so the driver has to be built out of tree.

#### Compared with `enable-front-panel-led.sh` (wifi-amlogic-w1 repo)

That script fixes the panel **on the devmfc image**. On this image it does not work, and it is not needed:

| What the script does | Why devmfc needs it | On this image |
|---|---|---|
| Patches the DTB in place (`/boot/dtb-<ver>/…x96x4.dtb`) | devmfc boots the X96 X4 DTB (TM1628, 3 wires, wrong pins) | The box's own DTB already has the FD6551 node on the right pins |
| Hook `/etc/kernel/postinst.d/zz-front-panel-led` | Every `linux-image` package ships an unpatched DTB | There is no `linux-image` package. The DTB ships with `kernel_magicsee` |
| `front-panel-led-map.service` + udev rule writing `map6` to `/sys/.../mapping` | The devmfc v1.97 driver uses the TM1628 default map and cannot read one from DT | The jefflessard driver reads the segment layout from DT (`digits/segments`) |
| Relies on the devmfc `tm16xx-display.service` | | Uses jefflessard's `display-service` (clock / IP) |

**The standard way**: describe the hardware in the DTB (an `i2c-gpio` node plus `fdhisi,fd6551`, jefflessard binding), build `tm16xx`/`tm16xx_i2c` with the kernel bundle, and keep userspace to writing content to `/sys/class/leds/*` and `/sys/.../message`.
Once `tm16xx` lands in mainline or in the ophub kernel, drop the self-built module. The DTB stays as it is.

What carries over from the wifi repo: the values verified on the real box (pins 35/36, FD6551, `map6`). The DTB node is based on them.

### IR keymaps (Android DTB `custom_maps`)

| Map | customcode | Keys |
|---|---|---|
| `amlogic-remote-1` | `0xf709` | 45 (the remote that ships with the box) |
| `amlogic-remote-2` | `0xfe01` | 53 |
| `amlogic-remote-3` | `0xbd02` | 17 |

Each `keymap` entry is `(scancode << 16) | linux_keycode`. It will be converted to `/etc/rc_keymaps/magicsee.toml` for `ir-keytable`.

---

## Drivers

| Module | Source | Why not the one in the ophub kernel |
|---|---|---|
| `aml_sdio`, `vlsicomm` (WiFi) | [thanhnhu/wifi-amlogic-w1](https://github.com/thanhnhu/wifi-amlogic-w1) | The ophub build lacks the SMP irqsave fix and the 5 GHz DFS fix |
| `sdio_bt` | [thanhnhu/aml_bt](https://github.com/thanhnhu/aml_bt) | Built against the `aml_sdio` above |
| `hci_uart` (`hci_aml` patched for W155S1) | [thanhnhu/aml_bt](https://github.com/thanhnhu/aml_bt) `kernel/hci_aml-w155s1.patch` | The ophub build only knows `w155s2`. The W155S1 needs 600 ms after reset, otherwise it fails with `tx timeout` |
| `tm16xx`, `tm16xx_i2c` (front panel) | [jefflessard/tm16xx-display](https://github.com/jefflessard/tm16xx-display) | Not in the ophub kernel |
| `meson-ir`, `i2c-gpio`, `line-display`, `leds-gpio` | in the ophub kernel | |

Userland packages added to the image: `bluez` (not in the base image) and `ir-keytable`.

### Kernel bundle

The box is too weak to **build drivers on the box**. A `.ko` only loads on the exact kernel it was built for:
`vermagic` must match character for character, and the ophub kernel has `MODVERSIONS` and `MODULE_FORCE_LOAD` off.
Upgrade the kernel but keep the old drivers and `modprobe` refuses them: **no WiFi, no BT, no front panel**.

So the drivers are built **on the build host (WSL)** and packaged **together with the kernel**, the way ophub and AmakerGame already do it:

- ophub `kernel_s905x4` already carries `vlsicomm`, `aml_sdio`… inside `modules-<kver>.tar.gz`. The drivers ship with the kernel, not separately.
- Model 601 (X96) uses its own kernel repository (`AmakerGame/amlogic-s9xxx-armbian`, tag `kernel_s905x4`), and `armbian-update` switches to it automatically.
- Model 602 does the same with the **`kernel_magicsee`** release tag in the `thanhnhu/amlogic-s9xxx-armbian` fork. Each `<kver>.tar.gz` asset holds:
  - `boot-<kver>.tar.gz`, `header-<kver>.tar.gz`: unchanged from ophub
  - `modules-<kver>.tar.gz`: ophub's, with the modules above replaced by builds from our sources, `depmod` re-run
  - `dtb-amlogic-<kver>.tar.gz`: ophub's, plus `meson-sc2-magicsee-n5-max-x4.dtb`
  - `sha256sums`, and a `BUILDINFO` recording the source commits

`rebuild` writes `KERNEL_REPO` and `KERNEL_TAGS` to `/etc/ophub-release`, so `armbian-update` on the box fetches the kernel with matching drivers by itself. Nothing is built on the box.

Built by [`magicsee/build-kernel-bundle.sh`](magicsee/build-kernel-bundle.sh) (flow A in [FLOW](FLOW.magicsee-n5-max-x4.md#a-kernel-bundle-kernel_magicsee)).

### How official Armbian handles this

- The kernel comes from apt (`linux-image-current-meson64`). Out-of-tree WiFi drivers are patched straight into the kernel source at build time (`armbian/build`, `drivers` patches), so they always ship with the kernel.
- Drivers that cannot be patched in use DKMS and build on the device. On a weak box that is slow, and it breaks when headers or RAM run short.
- The ophub image swaps the base image's kernel for the ophub kernel, but `linux-image-current-meson64` stays registered in dpkg. This image puts it on `apt-mark hold`, so `apt upgrade` cannot install the Armbian kernel over it.

---

## Status

| Item | Status |
|---|---|
| DTB (`meson-sc2-magicsee-n5-max-x4.dtb`) | ✅ compiles, ❓ not boot-tested |
| Model DB `602`, `different-files`, `rebuild` | ✅ (column 9 is still `s905x4/6.18.y`; it becomes `magicsee/6.18.y` once the `kernel_magicsee` release exists) |
| Ethernet, eMMC, SD, USB, HDMI video | ❓ waiting for a boot test |
| Kernel bundle `kernel_magicsee` (WiFi, BT, front panel) | ✅ `6.18.63` builds (vermagic, aliases, modules.dep checked), ❓ not boot-tested, not published |
| `bluez`, `ir-keytable`, IR keymap, `apt-mark hold` | ✅ `magicsee/build-image-post.sh` |
| Power LED | ✅ DTB, ❓ polarity not checked |
| Front panel | ✅ DTB (jefflessard binding), ❓ icon names to be checked on the box |
| Audio | ❌ not supported by the SC2 DTS yet |

---

## Files

```
README.magicsee-n5-max-x4{,.vi}.md            # this README (EN / VI)
FLOW.magicsee-n5-max-x4{,.vi}.md              # build / flash / kernel upgrade flow (EN / VI)
magicsee/build-kernel-bundle.sh               # flow A: builds the kernel_magicsee bundle
magicsee/patches/<repo>/*.patch              # build-time fixes for the driver repos
magicsee/dts/                                 # DTS source + Android DTB dump (not in the image)
build-armbian/armbian-files/
├── common-files/etc/model_database.conf      # row 602
├── platform-files/amlogic/bootfs/dtb/amlogic/
│   └── meson-sc2-magicsee-n5-max-x4.dtb      # compiled DTB
└── different-files/magicsee-n5-max-x4/
    ├── bootfs/                               # → /boot
    └── rootfs/                               # → /
rebuild                                       # release= update branch for 601/602
```

The DTB needs its own name because `rebuild` unpacks the kernel's DTBs **after** `different-files`; a file with the same name would be overwritten.

### Why `different-files` is bigger than for most boxes

Most Amlogic boards in `model_database.conf` use `uEnv.txt` / `extlinux.conf` / `armbianEnv.txt` from `platform-files`, and their DTB comes with the kernel, so they need few or no `different-files`.
Only two boards use `BOOT_CONF=boot.config`: 601 (X96 Max Plus Ultra) and 602 (this box). They boot S905X4 through the devmfc boot chain, which is what this box boots with today. That chain lives in `bootfs/`:

| File | Role |
|---|---|
| `aml_autoscript`, `s905_autoscript`, `emmc_autoscript`, `cfgload` | Entry points the vendor u-boot runs (first boot via the reset button / USB / eMMC), all of them load `bootscript` |
| `bootscript`, `boot.scr` | devmfc boot script: reads `boot.config`, then `box-config/*.config`, loads kernel + DTB |
| `boot.config` | `box=magicseen5maxx4`, kernel `release=` (updated by `rebuild`) |
| `box-config/box-magicseen5maxx4.config` | Which DTB to load |
| `box-config/kernel-6.x.y*.config`, `s4-*.config` | Kernel command line; `*-debug-*` are only used with `debug=y` (serial console) |

`rootfs/` only holds what the DTB cannot express: module autoload for the W1 chip, the regulatory domain, and the NEC protocol switch for the IR receiver.

### Why there is no Armbian u-boot for S905X4

On most Amlogic boxes ophub's generic `s905_autoscript` chain-loads a mainline u-boot (`u-boot.ext` = `u-boot-<soc>.bin` from [ophub/u-boot](https://github.com/ophub/u-boot)), and that u-boot runs the standard `uEnv.txt` / `boot.scr` flow.
For SC2 there is no such u-boot: mainline U-Boot does not support the SC2 family, and official Armbian (`armbian/build`) does not support S905X4.
`u-boot-s905x4.bin` in ophub/u-boot is a 4 MB **dump of the X96 Max Plus Ultra's own bootloader partition** ([ophub/u-boot#61](https://github.com/ophub/u-boot/pull/61)), added only so `rebuild`'s overload step finds a file. `rebuild` still copies it to `/boot`, but nothing loads it.

So the box's **stock vendor u-boot** (the one on eMMC) is what boots this image. It lacks the variables `uEnv.txt` relies on (`kernel_addr_r` …), which is why `bootfs/` carries the small u-boot scripts that work with it (`aml_autoscript` → `bootscript` → `boot.config`). They were written by devmfc, but they are only boot scripts: the kernel is ophub's, the drivers are ours, the rootfs is Armbian.

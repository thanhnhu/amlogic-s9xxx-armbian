# Magicsee N5 Max X4 — Armbian

[English](README.magicsee-n5-max-x4.md) | **Tiếng Việt**

[← README chính](README.md) · [Flow build / flash / nâng cấp kernel](FLOW.magicsee-n5-max-x4.vi.md)

Board support cho **Magicsee N5 Max X4** (Amlogic S905X4 / SC2) trên nền
[ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian).

| | |
|---|---|
| Model ID / Board | `602` / `magicsee-n5-max-x4` |
| BOOT_CONF | `boot.config` (bootscript devmfc, `box=magicseen5maxx4`) |
| Kernel | `kernel_magicsee` = `kernel_s905x4` của ophub **cộng** driver và DTB của box này (xem [Kernel bundle](#kernel-bundle)) |
| Branch | `magicsee-n5-max-x4/<armbian-version>`, ví dụ `magicsee-n5-max-x4/26.11.0` |

---

## Phương án tổng thể

1. **Phần cứng nằm hết trong DTB** của box (`meson-sc2-magicsee-n5-max-x4.dtb`): WiFi power, BT UART, IR, power LED, VFD, SD-CD.
   Không vá DTB trên box, không dùng overlay, không cần service để đẩy cấu hình phần cứng lúc boot.
2. **Driver build trên WSL và đi cùng kernel**: release `kernel_magicsee` = kernel `kernel_s905x4` của ophub cộng driver của mình (WiFi, BT, VFD) cộng DTB.
   Box **không build gì**. Không dùng DKMS, vì box yếu.
3. **Nâng kernel bằng `armbian-update`**: kernel, module và DTB được thay cùng lúc từ `kernel_magicsee`, nên driver luôn khớp version.
   Kernel Armbian trong dpkg được `apt-mark hold`.
4. **Image chỉ thêm gói tối thiểu cho phần cứng**: `bluez`, `ir-keytable`. Không cài gói ứng dụng.
5. **Mỗi version một branch** `magicsee-n5-max-x4/<ver>`. Branch cũ giữ nguyên để build lại khi cần.

Chi tiết: [Kernel bundle](#kernel-bundle) · [FLOW](FLOW.magicsee-n5-max-x4.vi.md).

---

## Phần cứng

| Thành phần | Chi tiết |
|---|---|
| SoC | Amlogic S905X4 (SC2), 4× Cortex-A55, Mali-G31 |
| Board gốc | `sc2_s905x4_ah212` (bản clone của X96 X4, devmfc `box=x96x4`) |
| RAM / eMMC | 4 GB / 32 GB (`mmcblk1`) |
| Ethernet | 100 Mbit, PHY nội (`rmii`) |
| WiFi + BT | Amlogic **W1 / W155S1** (SDIO `8888:8888`), BT qua UART `serial@fe080000` |
| Màn hình | VFD **FD6551** 2 dây, I²C bit-bang |
| IR | `remote_input_d5`, giao thức NEC |
| Power LED | GPIO `0x28`, nối thẳng vào board, không qua IC VFD |
| Nút | Chỉ có nút reset/update trong lỗ AV, do u-boot đọc. `gpio_keypad` và `adc_keypad` trong Android đều `disabled` |
| Audio | HDMI/SPDIF có trong Android, **chưa có** trong DTS mainline SC2 |

### Bảng GPIO

Dùng cùng kiểu đánh số trong DTB Android (phandle `0x1b`) và DTB Magicsee (phandle `0x13`). Tên chân theo `dt-bindings/gpio/meson-sc2-gpio.h`.

| GPIO | Chân | Chức năng | Node trong DTB Magicsee |
|---|---|---|---|
| `0x18` | | SD card detect | `sd@fe08a000 cd-gpios` |
| `0x23` (35) | GPIOD_6 | VFD clk | `i2c-display scl-gpios` |
| `0x24` (36) | GPIOD_7 | VFD dat | `i2c-display sda-gpios` |
| `0x28` | | Power LED | `leds/led-power` (`default-state = "keep"`) |
| `0x38` | | WiFi power/reset | `sdio-pwrseq reset-gpios`, `aml_wifi power_on-gpios` |
| `0x39` | | WiFi host-wake | `aml_wifi interrupt-gpios` |
| `0x43` | | BT enable | `serial@80000/bluetooth enable-gpios` |
| `0x45` | | BT host-wake | `interrupts = <0x5f …>` qua gpio-intc |

### VFD (FD6551)

- Nguồn: Android openvfd [`magicsee-n5-max-x4-vfd.conf`](https://github.com/arthur-liberman/vfd-configurations/blob/master/magicsee-n5-max-x4-vfd.conf):
  `clk=35`, `dat=36`, không có STB, `display_type=0x01,0x00,0x00,0x06` (T95, FD6551).
- Driver: [jefflessard/tm16xx-display](https://github.com/jefflessard/tm16xx-display) (`tm16xx`, `tm16xx_i2c`), build ngoài kernel. Repo này có sẵn [`devices/magicsee-n5-max-x4.dtso`](https://github.com/jefflessard/tm16xx-display/blob/main/devices/magicsee-n5-max-x4.dtso).
- Bảng segment: byte 1–4, bit `3 4 5 0 1 2 6`. Khớp với `map6` của driver devmfc mà box đang dùng.
- Box hiện tại (kernel devmfc 6.18.40) dùng driver `tm16xx` **build sẵn trong kernel devmfc**, với compatible `devmfc,fd6551`. Kernel ophub không có driver này.
- Linux mainline (7.4) cũng chưa có `tm16xx`, nên driver vẫn phải build ngoài kernel.

#### So với `enable-front-panel-led.sh` (repo wifi-amlogic-w1)

Script đó là cách sửa **trên image devmfc**. Trên image này không dùng được và cũng không cần:

| Script làm | Vì sao trên devmfc cần | Trên image này |
|---|---|---|
| Vá DTB tại chỗ (`/boot/dtb-<ver>/…x96x4.dtb`) | Image devmfc boot DTB của X96 X4 (TM1628 3 dây, sai chân) | DTB riêng của box đã có sẵn node FD6551 đúng chân |
| Hook `/etc/kernel/postinst.d/zz-front-panel-led` | Mỗi gói `linux-image` mang DTB chưa vá | Không có gói `linux-image`. DTB đi kèm `kernel_magicsee` |
| `front-panel-led-map.service` + udev rule đẩy `map6` vào `/sys/.../mapping` | Driver devmfc v1.97 chỉ lấy map mặc định TM1628, không đọc map từ DT | Driver jefflessard đọc bảng segment từ DT (`digits/segments`) |
| Dựa vào `tm16xx-display.service` của gói devmfc | | Dùng `display-service` của jefflessard (hiện giờ/IP) |

**Cách chuẩn nhất**: mô tả phần cứng trong DTB (node `i2c-gpio` + `fdhisi,fd6551`, theo binding của jefflessard). Driver `tm16xx`/`tm16xx_i2c` build cùng kernel bundle. Userspace chỉ ghi nội dung lên `/sys/class/leds/*` và `/sys/.../message`.
Khi nào `tm16xx` vào mainline (hoặc vào kernel ophub) thì bỏ module tự build đi. DTB giữ nguyên.

Phần giữ lại từ repo wifi: các giá trị đã kiểm chứng trên máy thật (chân 35/36, FD6551, `map6`). Đây là căn cứ của node trong DTB.

### Keymap IR (DTB Android `custom_maps`)

| Map | customcode | Số phím |
|---|---|---|
| `amlogic-remote-1` | `0xf709` | 45 (remote đi kèm box) |
| `amlogic-remote-2` | `0xfe01` | 53 |
| `amlogic-remote-3` | `0xbd02` | 17 |

Mỗi phần tử `keymap` = `(scancode << 16) | linux_keycode`. Sẽ chuyển thành `/etc/rc_keymaps/magicsee.toml` để `ir-keytable` nạp.

---

## Driver

| Module | Source | Vì sao không dùng bản trong kernel ophub |
|---|---|---|
| `aml_sdio`, `vlsicomm` (WiFi) | [thanhnhu/wifi-amlogic-w1](https://github.com/thanhnhu/wifi-amlogic-w1) | Bản ophub thiếu sửa lỗi irqsave khi chạy SMP và sửa DFS 5 GHz |
| `sdio_bt` | [thanhnhu/aml_bt](https://github.com/thanhnhu/aml_bt) | Đi cùng bộ với `aml_sdio` ở trên |
| `hci_uart` (`hci_aml` đã patch cho W155S1) | [thanhnhu/aml_bt](https://github.com/thanhnhu/aml_bt) `kernel/hci_aml-w155s1.patch` | Bản ophub chỉ biết `w155s2`. W155S1 cần chờ 600 ms sau reset, không thì báo `tx timeout` |
| `tm16xx`, `tm16xx_i2c` (VFD) | [jefflessard/tm16xx-display](https://github.com/jefflessard/tm16xx-display) | Kernel ophub không có |
| `meson-ir`, `i2c-gpio`, `line-display`, `leds-gpio` | có trong kernel ophub | |

Gói userland cần thêm vào image: `bluez` (base image không có) và `ir-keytable`.

### Kernel bundle

Box yếu, nên **không build driver trên box**. Module `.ko` chỉ load được trên đúng kernel mà nó được build cùng:
`vermagic` phải khớp từng ký tự, kernel ophub tắt `MODVERSIONS` và `MODULE_FORCE_LOAD`.
Nếu nâng kernel mà vẫn giữ driver cũ thì `modprobe` sẽ từ chối: **mất WiFi, BT và VFD**.

Vì vậy driver được build **trên máy build (WSL)** và đóng gói **cùng với kernel**, đúng như ophub và AmakerGame đang làm:

- `kernel_s905x4` của ophub đã có `vlsicomm`, `aml_sdio`… nằm sẵn trong `modules-<kver>.tar.gz`. Driver đi kèm kernel, không cài riêng.
- Model 601 (X96) dùng repo kernel riêng (`AmakerGame/amlogic-s9xxx-armbian`, tag `kernel_s905x4`), và `armbian-update` tự trỏ sang repo đó.
- Model 602 làm tương tự: release tag **`kernel_magicsee`** trong fork `thanhnhu/amlogic-s9xxx-armbian`. Mỗi asset `<kver>.tar.gz` gồm:
  - `boot-<kver>.tar.gz`, `header-<kver>.tar.gz`: giữ nguyên của ophub
  - `modules-<kver>.tar.gz`: bản của ophub, thay các module ở bảng trên bằng bản build từ source của mình, chạy `depmod` lại
  - `dtb-amlogic-<kver>.tar.gz`: bản của ophub, thêm `meson-sc2-magicsee-n5-max-x4.dtb`
  - `sha256sums`

`rebuild` ghi `KERNEL_REPO` và `KERNEL_TAGS` vào `/etc/ophub-release`. Nhờ đó trên box, `armbian-update` tự tải kernel kèm driver đúng phiên bản, không phải build gì.

### Armbian chính thức xử lý chuyện này thế nào

- Kernel cài qua apt (`linux-image-current-meson64`). Driver WiFi ngoài kernel được Armbian patch thẳng vào source kernel lúc build (`armbian/build`, phần `drivers`), nên luôn đi cùng kernel.
- Driver không patch được thì dùng DKMS và build trên máy. Trên box yếu thì chậm, và lỗi khi thiếu header hoặc thiếu RAM.
- Image ophub thay kernel của base image bằng kernel ophub, nhưng gói `linux-image-current-meson64` vẫn còn trong dpkg. Image này sẽ `apt-mark hold` gói đó, để `apt upgrade` không cài kernel Armbian chen vào.

---

## Trạng thái

| Hạng mục | Trạng thái |
|---|---|
| DTB (`meson-sc2-magicsee-n5-max-x4.dtb`) | ✅ compile OK, ❓ chưa boot thử |
| Model DB `602`, `different-files`, `rebuild` | ✅ (cột 9 vẫn là `s905x4/6.18.y`, sẽ đổi sang `magicsee/6.18.y` khi có release `kernel_magicsee`) |
| Ethernet, eMMC, SD, USB, HDMI video | ❓ chờ boot thử |
| Kernel bundle `kernel_magicsee` (WiFi, BT, VFD) | ✅ build được bản `6.18.63` (đã kiểm tra vermagic, alias, modules.dep), ❓ chưa boot thử, chưa publish |
| `bluez`, `ir-keytable`, keymap IR, `apt-mark hold` | ✅ `magicsee/build-image-post.sh` |
| Power LED | ✅ DTB, ❓ chưa kiểm tra polarity |
| VFD | ✅ DTB (binding jefflessard), ❓ tên các icon cần kiểm tra trên máy |
| Audio | ❌ DTS SC2 chưa hỗ trợ |

---

## File trong repo

```
README.magicsee-n5-max-x4{,.vi}.md            # README box (EN / VI)
FLOW.magicsee-n5-max-x4{,.vi}.md              # quy trình build / flash / nâng kernel (EN / VI)
magicsee/build-kernel-bundle.sh               # quy trình A: tạo kernel bundle kernel_magicsee
magicsee/patches/<repo>/*.patch              # bản sửa lúc build cho các repo driver
magicsee/dts/                                 # source DTS + dump DTB Android (không vào image)
build-armbian/armbian-files/
├── common-files/etc/model_database.conf      # dòng 602
├── platform-files/amlogic/bootfs/dtb/amlogic/
│   └── meson-sc2-magicsee-n5-max-x4.dtb      # DTB đã compile
└── different-files/magicsee-n5-max-x4/
    ├── bootfs/                               # → /boot
    └── rootfs/                               # → /
rebuild                                       # nhánh cập nhật release= cho 601/602
```

DTB phải đặt tên riêng vì `rebuild` giải nén DTB của kernel **sau** `different-files`. File trùng tên sẽ bị ghi đè.

### Vì sao `different-files` của box này nhiều hơn các box khác

Phần lớn box Amlogic trong `model_database.conf` dùng `uEnv.txt` / `extlinux.conf` / `armbianEnv.txt` có sẵn trong `platform-files`, DTB thì đi kèm kernel, nên chúng cần rất ít hoặc không cần `different-files`.
Chỉ có 2 board dùng `BOOT_CONF=boot.config`: 601 (X96 Max Plus Ultra) và 602 (box này). Cả hai boot S905X4 bằng chuỗi boot của devmfc, cũng là chuỗi box đang dùng để boot hiện nay. Chuỗi này nằm trong `bootfs/`:

| File | Vai trò |
|---|---|
| `aml_autoscript`, `s905_autoscript`, `emmc_autoscript`, `cfgload` | Điểm vào mà u-boot gốc chạy (boot lần đầu bằng nút reset / USB / eMMC), tất cả đều gọi `bootscript` |
| `bootscript`, `boot.scr` | Script boot của devmfc: đọc `boot.config`, rồi `box-config/*.config`, nạp kernel và DTB |
| `boot.config` | `box=magicseen5maxx4`, kernel `release=` (do `rebuild` cập nhật) |
| `box-config/box-magicseen5maxx4.config` | Chọn DTB cần nạp |
| `box-config/kernel-6.x.y*.config`, `s4-*.config` | Kernel cmdline; các file `*-debug-*` chỉ dùng khi `debug=y` (serial console) |

`rootfs/` chỉ chứa những gì DTB không diễn tả được: tự load module cho chip W1, regdom, và bật giao thức NEC cho IR.

### Vì sao S905X4 không có u-boot của Armbian

Trên phần lớn box Amlogic, `s905_autoscript` chung của ophub chain-load sang u-boot mainline (`u-boot.ext` = `u-boot-<soc>.bin` từ [ophub/u-boot](https://github.com/ophub/u-boot)), rồi u-boot đó chạy luồng `uEnv.txt` / `boot.scr` chuẩn.
SC2 thì không có u-boot như vậy: U-Boot mainline chưa hỗ trợ dòng SC2, và Armbian chính thức (`armbian/build`) không hỗ trợ S905X4.
File `u-boot-s905x4.bin` trong ophub/u-boot thực ra là **bản dump 4 MB của phân vùng bootloader gốc trên box X96 Max Plus Ultra** ([ophub/u-boot#61](https://github.com/ophub/u-boot/pull/61)). Nó được thêm vào chỉ để bước overload của `rebuild` tìm thấy file. `rebuild` vẫn copy nó vào `/boot`, nhưng không có gì nạp nó.

Vì vậy người boot image này là **u-boot gốc của box** (nằm trên eMMC). U-boot đó thiếu các biến mà `uEnv.txt` cần (`kernel_addr_r` …), nên `bootfs/` phải mang theo mấy script nhỏ chạy được với nó (`aml_autoscript` → `bootscript` → `boot.config`). Các script này do devmfc viết, nhưng chỉ là script boot: kernel là của ophub, driver là của mình, rootfs là Armbian.

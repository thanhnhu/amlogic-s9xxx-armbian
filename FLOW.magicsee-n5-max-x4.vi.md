# Magicsee N5 Max X4 — Flow

[English](FLOW.magicsee-n5-max-x4.md) | **Tiếng Việt**

[← README chính](README.md) · [README box](README.magicsee-n5-max-x4.vi.md)

Có 3 quy trình tách riêng:

| Quy trình | Khi nào chạy | Kết quả |
|---|---|---|
| **A. Kernel bundle** | Mỗi khi `kernel_s905x4` của ophub có bản mới, hoặc driver/DTB thay đổi | Release `kernel_magicsee/<kver>.tar.gz` |
| **B. Image** | Khi cần image mới (Armbian/Debian mới, đổi rootfs) | `Armbian_*_magicsee-n5-max-x4_*.img.xz` |
| **C. Nâng kernel trên box** | Sau khi có bundle mới | Box chạy kernel mới, driver khớp version |

Box **không bao giờ tự build** driver. Mọi thứ build trên WSL.

---

## 0. Môi trường (WSL Debian)

```bash
# Clone trong filesystem của WSL, không build từ /mnt/d (core.symlinks=false trên Windows làm hỏng symlink)
git clone -b magicsee-n5-max-x4/26.11.0 git@github.com:thanhnhu/amlogic-s9xxx-armbian.git ~/amlogic-armbian
git clone git@github.com:thanhnhu/wifi-amlogic-w1.git       ~/src/wifi-amlogic-w1
git clone git@github.com:thanhnhu/aml_bt.git                ~/src/aml_bt
git clone https://github.com/jefflessard/tm16xx-display.git ~/src/tm16xx-display

sudo apt-get install -y $(curl -fsSL https://ophub.org/ubuntu2604-build-armbian-depends)
sudo apt-get install -y device-tree-compiler gcc-aarch64-linux-gnu bc bison flex libssl-dev kmod \
                        qemu-user-static binfmt-support
```

---

## A. Kernel bundle `kernel_magicsee` (`magicsee/build-kernel-bundle.sh`)

```bash
./magicsee/build-kernel-bundle.sh 6.18.63          # ra ~/magicsee-out/6.18.63.tar.gz
```

Biến môi trường: `WIFI_SRC`, `BT_SRC`, `TM16XX_SRC` (mặc định `~/src/...`), `TM16XX_REF` (commit ghim), `OUT`, `WORK`. Script không upload gì.

Các bước script làm:

1. Tải `https://github.com/ophub/kernel/releases/download/kernel_s905x4/<kver>.tar.gz`, kiểm tra `sha256sums`.
2. Giải nén `header-<kver>-meson64.tar.gz`, rồi chạy `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig scripts modules_prepare`. Header của ophub không có sẵn `fixdep`/`modpost`.
3. Cross-compile với header đó:
   - `wifi-amlogic-w1/project_w1` → `aml_sdio.ko`, `vlsicomm.ko`
   - `aml_bt` → `sdio_bt.ko`. Lấy `drivers/bluetooth` của đúng `<kver>`, áp `kernel/hci_aml-w155s1.patch`, build ra `hci_uart.ko`
   - `tm16xx-display` → `tm16xx.ko`, `tm16xx_i2c.ko`

   Các bản sửa lúc build nằm trong `magicsee/patches/<repo>/*.patch`, áp vào bản copy nên không sửa repo driver.
   Ví dụ `wifi-amlogic-w1/0001-rename-michael_mic.patch`: kernel 6.18.63 thêm hàm `michael_mic()` toàn cục, trùng tên với hàm static của driver.
4. Giải nén `modules-<kver>-meson64.tar.gz`. Ghi đè module cùng tên vào đúng chỗ (`kernel/drivers/net/wireless/amlogic/`, `kernel/drivers/bluetooth/`), thêm module mới vào `kernel/drivers/auxdisplay/`. Chạy `depmod -b <staging> <kver>-meson64` trên host (depmod không phụ thuộc kiến trúc). Nén lại.
5. Compile `magicsee/dts/meson-sc2-magicsee-n5-max-x4.dts`, thêm vào `dtb-amlogic-<kver>-meson64.tar.gz`.
6. Tạo lại `sha256sums`, đóng gói `<kver>.tar.gz`, upload lên release tag `kernel_magicsee` của fork:
   `gh release upload kernel_magicsee <kver>.tar.gz --repo thanhnhu/amlogic-s9xxx-armbian --clobber`

Kiểm tra trước khi upload: `modinfo -F vermagic` của mọi module mới phải khớp `vermagic` của module ophub trong cùng bundle.

---

## B. Image

### B1. Base image

Lấy từ release `Armbian_trixie_arm64_server_<YYYY.MM>` của ophub (file `*-trunk_*.img.gz`).

```bash
mkdir -p ~/amlogic-armbian/build/output/images
gzip -dc ~/armbian-base/Armbian_26.11.0-trunk_trixie_arm64_6.18.64.img.gz \
  > ~/amlogic-armbian/build/output/images/Armbian_26.11.0-trunk_trixie_arm64_6.18.64.img
```

Base image chỉ có một phân vùng ext4 (bắt đầu từ sector 8192), đã có sẵn `dkms`/`gcc`/`network-manager`/`wpasupplicant`/`iw`, **chưa có** `bluez` và `ir-keytable`.

### B2. Rebuild

```bash
cd ~/amlogic-armbian
# Khi chưa có kernel_magicsee: cột 9 = s905x4/6.18.y (kernel ophub, driver WiFi/BT/VFD chưa đúng)
# Khi đã có kernel_magicsee:   cột 9 = magicsee/6.18.y
sudo ./rebuild -b magicsee-n5-max-x4 -k 6.18.y -r thanhnhu/amlogic-s9xxx-armbian
```

`rebuild` tải kernel từ `<repo>/releases/download/kernel_<tag>/<kver>.tar.gz`, ngoài ra tải `ophub/u-boot` và `ophub/firmware` (`aml/w1_bt_fw_uart.bin`, `aml_wifi_*`).
Nó cũng ghi `KERNEL_REPO` và `KERNEL_TAGS` vào `/etc/ophub-release`, để `armbian-update` trên box dùng đúng repo.

### B3. Hậu xử lý image (`magicsee/build-image-post.sh`)

```bash
sudo ./magicsee/build-image-post.sh build/output/images/Armbian_*_magicsee-n5-max-x4_*.img.gz
```

Script mount image rồi chroot vào qua `qemu-aarch64-static`:

1. `apt-get install --no-install-recommends bluez ir-keytable`
2. `apt-mark hold` các gói `linux-image-*` / `linux-dtb-*` / `linux-u-boot-*` đã cài trong base image
3. `/etc/rc_keymaps/magicsee.toml` (từ `amlogic-remote-1`, `0xf709`) và một dòng `meson-ir` trong `/etc/rc_maps.cfg`; udev rule của `ir-keytable` nạp keymap khi `rc0` xuất hiện
4. Service hiển thị VFD (giờ/IP): `display-service` + `display.service` của jefflessard
5. Chưa làm: `wlan-5g-warmup` (từ repo wifi)
5. `apt-get clean`, xoá `qemu-aarch64-static`, unmount, nén `.img.xz` cùng `sha256`

### B4. DTB trong repo

`platform-files/amlogic/bootfs/dtb/amlogic/meson-sc2-magicsee-n5-max-x4.dtb` phải được build lại mỗi khi sửa DTS:

```bash
cd ~/amlogic-armbian/build-armbian/armbian-files
dtc -I dts -O dtb \
  -o platform-files/amlogic/bootfs/dtb/amlogic/meson-sc2-magicsee-n5-max-x4.dtb \
  ~/amlogic-armbian/magicsee/dts/meson-sc2-magicsee-n5-max-x4.dts
```

dtc in ra các cảnh báo `clocks_property` / `unit_address`. Đó là chuyện bình thường với DTS decompile từ DTB.

---

## C. Nâng kernel trên box

```bash
armbian-update              # tự lấy KERNEL_REPO / KERNEL_TAGS trong /etc/ophub-release
armbian-update -k 6.18.70   # hoặc chọn version cụ thể
```

Kernel, module (kèm driver của mình) và DTB được thay **cùng lúc**, nên không bao giờ lệch version.
Đừng dùng `apt` để nâng kernel. Gói kernel Armbian đã được hold sẵn.

---

## D. Flash và kiểm tra (USB trước, chưa động vào eMMC)

1. Ghi image ra USB (BalenaEtcher / `dd`). Thẻ SD không boot được trên box này.
2. Cắm USB, giữ nút reset trong lỗ AV, cấp nguồn, giữ khoảng 7 giây.
3. Kiểm tra:

```bash
cat /proc/device-tree/model                            # Magicsee N5 Max X4
modinfo -F vermagic vlsicomm hci_uart tm16xx           # cùng một kernel với uname -r
ip -br link; iw dev                                    # eth0, wlan0
hciconfig; dmesg | grep -i fw_version                  # hci0 UP, có fw_version
ls /sys/class/rc/rc0; ir-keytable -t                   # bấm remote thấy scancode/key
ls /sys/class/leds                                     # power, *::colon, *::usb, ...
cat /sys/class/thermal/thermal_zone*/temp
```

4. Ổn định rồi mới cài lên eMMC (`armbian-install`). Trước đó backup eMMC hiện tại (Debian devmfc):
   `dd if=/dev/mmcblk1 bs=4M status=progress | gzip -1 > emmc_debian_backup.img.gz`

---

## E. Lên version mới (branch)

```bash
git switch magicsee-n5-max-x4/26.11.0
git switch -c magicsee-n5-max-x4/<ver-mới>
git fetch upstream && git rebase upstream/main
```

Branch cũ giữ nguyên để build lại khi cần. Sau khi rebase, kiểm tra lại: format của `model_database.conf`, nhánh `release=` trong `rebuild`, dòng s905x4 trong `README.md`.

---

## F. Kernel 7 (sau này)

- SC2 chưa có trong Linux mainline. `kernel_s905x4` dựa trên patch của devmfc (`devmfc/linux` public tới `meson64-6.14`).
- Cần: tree 7.x cộng patch SC2 (pinctrl, clk, pwrc, dwmac, mmc, `meson-s4-dw-hdmi`, `meson-s4-ir`), tự build kernel thay cho bước A1.
  Các bước A2–A6 giữ nguyên. Đổi cột 9 của dòng 602 thành `magicsee/7.x.y`.
- Driver phải port theo API 7.x. Giữ bundle 6.18 làm bản dự phòng.

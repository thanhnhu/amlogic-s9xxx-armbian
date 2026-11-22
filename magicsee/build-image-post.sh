#!/usr/bin/env bash
#
# Post-process a rebuilt Magicsee N5 Max X4 image (flow B3).
#
#   sudo ./magicsee/build-image-post.sh build/output/images/Armbian_*_magicsee-n5-max-x4_*.img.gz
#
# Adds what the hardware needs and rebuild cannot do (rebuild only copies files):
#   - bluez (BT userland) and ir-keytable, installed in a qemu chroot
#   - apt-mark hold on the Armbian kernel packages left over from the base image
#   - IR keymap of the stock remote (Android custom_maps map_0, customcode 0xf709)
#   - pin /boot to this image's UUID, enable the front-panel clock service
# Writes <name>.img.gz next to the input (the input is replaced).
#
# Needs: qemu-user-static + binfmt-support (aarch64 registered), python3, gzip/pigz,
# network access for apt inside the chroot.
set -euo pipefail

IMG_IN="${1:-}"
[[ -f "${IMG_IN}" ]] || { echo "usage: $0 <image.img[.gz]>" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DTS="${ANDROID_DTS:-${REPO_ROOT}/magicsee/dts/android-stock-sc2_s905x4_ah212.dts}"
PACKAGES=(bluez ir-keytable)

log() { echo -e "\n==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# An arm64 host (e.g. a GitHub arm runner) runs the chroot natively; an x86 host needs qemu.
if [[ "$(uname -m)" != "aarch64" ]]; then
    ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q aarch64 || die "qemu aarch64 binfmt is not registered"
fi
[[ -f "${ANDROID_DTS}" ]] || die "missing ${ANDROID_DTS}"

IMG="${IMG_IN%.gz}"
if [[ "${IMG_IN}" == *.gz ]]; then
    log "Decompressing $(basename "${IMG_IN}")"
    gzip -dc "${IMG_IN}" > "${IMG}"
fi

MNT="$(mktemp -d)"
LOOPS=()
cleanup() {
    set +e
    for m in dev/pts dev proc sys run boot; do mountpoint -q "${MNT}/${m}" && umount -l "${MNT}/${m}"; done
    mountpoint -q "${MNT}" && umount -l "${MNT}"
    for l in "${LOOPS[@]}"; do losetup -d "${l}"; done
    rmdir "${MNT}" 2>/dev/null
}
trap cleanup EXIT

# WSL has no udev, so partition nodes of a loop device never appear: map each
# partition with its own offset/sizelimit loop instead.
log "Mounting image"
mapfile -t PARTS < <(sfdisk -d "${IMG}" | awk -F'[=,]' '/start=/ {gsub(/ /,"",$2); gsub(/ /,"",$4); print $2" "$4}')
[[ "${#PARTS[@]}" -ge 2 ]] || die "expected boot + rootfs partitions"
part_loop() {
    local start size
    read -r start size <<<"$1"
    losetup -f --show -o $((start * 512)) --sizelimit $((size * 512)) "${IMG}"
}
BOOT_LOOP="$(part_loop "${PARTS[0]}")"; LOOPS+=("${BOOT_LOOP}")
ROOT_LOOP="$(part_loop "${PARTS[1]}")"; LOOPS+=("${ROOT_LOOP}")
mount "${ROOT_LOOP}" "${MNT}"
mount "${BOOT_LOOP}" "${MNT}/boot"
for m in proc sys dev dev/pts run; do mkdir -p "${MNT}/${m}"; mount --bind "/${m}" "${MNT}/${m}"; done
[[ -f "${MNT}/etc/ophub-release" ]] || die "not an ophub-rebuilt image"
grep -q "magicsee-n5-max-x4" "${MNT}/etc/ophub-release" || die "image is not for magicsee-n5-max-x4"

# rebuild only rewrites LABEL=BOOT to a UUID for ext4 boot partitions; this one is
# vfat. A box whose eMMC still holds another system with a "BOOT" partition (the
# devmfc Debian, for one) would then mount the eMMC's /boot while running from USB,
# and armbian-update would write the kernel there. Pin /boot to this image's UUID.
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_LOOP}")"
[[ -n "${BOOT_UUID}" ]] || die "cannot read the boot partition UUID"
sed -i "s|^LABEL=BOOT[[:space:]].*|UUID=${BOOT_UUID}  /boot  vfat  defaults  0 2|" "${MNT}/etc/fstab"
grep -q "^UUID=${BOOT_UUID} " "${MNT}/etc/fstab" || die "fstab has no /boot entry to pin"
echo "    /boot -> UUID=${BOOT_UUID}"

RESOLV_BAK=""
if [[ -e "${MNT}/etc/resolv.conf" || -L "${MNT}/etc/resolv.conf" ]]; then
    RESOLV_BAK="$(mktemp)"; cp -P "${MNT}/etc/resolv.conf" "${RESOLV_BAK}"; rm -f "${MNT}/etc/resolv.conf"
fi
cp /etc/resolv.conf "${MNT}/etc/resolv.conf"

in_chroot() { chroot "${MNT}" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

# ------------------------------------------------------------------ packages
log "Installing ${PACKAGES[*]}"
in_chroot apt-get update -qq
in_chroot apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}"

log "Holding Armbian kernel packages"
# dpkg-query also lists virtual/unknown names (linux-image-armbian); keep installed ones only
mapfile -t HOLD < <(in_chroot dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' 2>/dev/null |
    awk '$1 == "installed" {print $2}' || true)
if [[ "${#HOLD[@]}" -gt 0 ]]; then in_chroot apt-mark hold "${HOLD[@]}"; fi

# ------------------------------------------------------------------ IR keymap
log "IR keymap (amlogic-remote-1, customcode 0xf709)"
mkdir -p "${MNT}/etc/rc_keymaps"
python3 -I - "${ANDROID_DTS}" "${MNT}/usr/include/linux/input-event-codes.h" /usr/include/linux/input-event-codes.h \
    > "${MNT}/etc/rc_keymaps/magicsee.toml" <<'PY'
import re, sys, os
dts, *hdrs = sys.argv[1:]
hdr = next(h for h in hdrs if os.path.exists(h))
names = {}
for m in re.finditer(r'#define\s+(KEY_\w+|BTN_\w+)\s+(0x[0-9a-fA-F]+|\d+)', open(hdr).read()):
    names.setdefault(int(m.group(2), 0), m.group(1))
t = open(dts).read()
blk = re.search(r'map_0\s*\{(.*?)\};', t, re.S).group(1)
code = int(re.search(r'customcode\s*=\s*<(0x[0-9a-f]+)>', blk).group(1), 16)
addr = code & 0xff                      # NEC: low byte address, high byte its inverse
km = [int(x, 16) for x in re.search(r'keymap\s*=\s*<([^>]*)>', blk).group(1).split()]
print('# Magicsee N5 Max X4 stock remote (Android custom_maps map_0, customcode 0x%04x)' % code)
print('[[protocols]]\nname = "magicsee"\nprotocol = "nec"\nvariant = "nec"\n[protocols.scancodes]')
for e in km:
    sc, key = e >> 16, e & 0xffff
    if key in names:
        print('0x%02x%02x = "%s"' % (addr, sc, names[key]))
PY
grep -c '= "' "${MNT}/etc/rc_keymaps/magicsee.toml" | xargs -I{} echo "    {} keys"
# ir-keytable's udev rule loads tables listed in rc_maps.cfg when rc0 appears
RCMAPS="${MNT}/etc/rc_maps.cfg"
touch "${RCMAPS}"
grep -q 'magicsee.toml' "${RCMAPS}" || sed -i '1i meson-ir\t*\t/etc/rc_keymaps/magicsee.toml' "${RCMAPS}"

# ------------------------------------------------------------------ front panel
# magicsee-panel (clock on the FD6551) ships in different-files; enable it here so
# the board directory needs no symlink in git.
log "Front-panel clock service"
[[ -x "${MNT}/usr/local/sbin/magicsee-panel" ]] || die "magicsee-panel missing from the image"
in_chroot systemctl enable magicsee-panel.service

# ------------------------------------------------------------------ finish
log "Cleaning up"
in_chroot apt-get clean
rm -rf "${MNT}"/var/lib/apt/lists/*
rm -f "${MNT}/etc/resolv.conf"
[[ -n "${RESOLV_BAK}" ]] && cp -P "${RESOLV_BAK}" "${MNT}/etc/resolv.conf" && rm -f "${RESOLV_BAK}"
echo "magicsee-post $(git -C "${REPO_ROOT}" describe --always --dirty 2>/dev/null || echo local) $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "${MNT}/etc/ophub-release.magicsee"
sync
cleanup
trap - EXIT

log "Compressing"
if command -v pigz >/dev/null; then pigz -f "${IMG}"; else gzip -f "${IMG}"; fi
sha256sum "${IMG}.gz" | tee "${IMG}.gz.sha256"

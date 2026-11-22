#!/usr/bin/env bash
#
# Build the kernel_magicsee bundle for the Magicsee N5 Max X4 (model 602).
#
#   ./magicsee/build-kernel-bundle.sh 6.18.59
#
# Takes the ophub kernel_s905x4 package for <kver>, cross-compiles the box's
# out-of-tree drivers against its headers, swaps them into the modules tarball,
# adds the Magicsee DTB to the dtb tarball and writes a new <kver>.tar.gz in the
# exact layout rebuild / armbian-update expect:
#
#   <kver>/{boot,dtb-amlogic,header,modules}-<kver>-meson64.tar.gz + sha256sums
#
# Drivers (all built here, never on the box):
#   aml_sdio, vlsicomm   thanhnhu/wifi-amlogic-w1   (SMP irqsave + DFS fixes)
#   sdio_bt              thanhnhu/aml_bt
#   hci_uart             upstream drivers/bluetooth of <kver> + aml_bt/kernel/hci_aml-w155s1.patch
# The front panel (FD6551) uses the tm16xx driver built into the devmfc base kernel.
#
# Nothing is uploaded. Publish with:
#   gh release upload kernel_magicsee <out>/<kver>.tar.gz --repo <owner>/amlogic-s9xxx-armbian --clobber
#
# Runs as a normal user on Debian/Ubuntu: cross-compiles on x86_64 (WSL is fine),
# builds natively on arm64 (the build-magicsee GitHub workflow). Needs:
#   make bc bison flex libssl-dev libelf-dev kmod device-tree-compiler curl git patch
#   + gcc-aarch64-linux-gnu on x86_64
set -euo pipefail

KVER="${1:-${KVER:-}}"
[[ -n "${KVER}" ]] || { echo "usage: $0 <kernel-version, e.g. 6.18.59>" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_REPO="${SRC_REPO:-ophub/kernel}"
SRC_TAG="${SRC_TAG:-kernel_s905x4}"
KSUFFIX="${KSUFFIX:-meson64}"
WIFI_SRC="${WIFI_SRC:-${HOME}/src/wifi-amlogic-w1}"
BT_SRC="${BT_SRC:-${HOME}/src/aml_bt}"
DTS="${DTS:-${REPO_ROOT}/magicsee/dts/meson-sc2-magicsee-n5-max-x4.dts}"
DTB_NAME="meson-sc2-magicsee-n5-max-x4.dtb"
WORK="${WORK:-${HOME}/magicsee-work/${KVER}}"
OUT="${OUT:-${HOME}/magicsee-out}"
# Native on an arm64 host (GitHub arm runner), cross-compile on x86 (WSL); CROSS_COMPILE overrides.
if [[ -n "${CROSS_COMPILE+x}" ]]; then
    XC="${CROSS_COMPILE}"
elif [[ "$(uname -m)" == "aarch64" ]]; then
    XC=""
else
    XC="aarch64-linux-gnu-"
fi
JOBS="${JOBS:-$(nproc)}"

KREL="${KVER}-${KSUFFIX}"
MK=(make -j"${JOBS}" ARCH=arm64 CROSS_COMPILE="${XC}")

PATCHES="${PATCHES:-${REPO_ROOT}/magicsee/patches}"

log() { echo -e "\n==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# apply_patches <patch-subdir> <target-dir> <strip>
# Build-time fixes kept in this repo, so the driver repos stay untouched.
apply_patches() {
    local p
    for p in "${PATCHES}/$1"/*.patch; do
        [[ -f "${p}" ]] || continue
        echo "    patch: $1/$(basename "${p}")"
        patch -d "$2" -p"$3" --forward --no-backup-if-mismatch < "${p}"
    done
}

for t in "${XC}gcc" "${XC}strip" make dtc depmod curl git patch; do
    command -v "${t}" >/dev/null || die "missing tool: ${t}"
done
for d in "${WIFI_SRC}/project_w1" "${BT_SRC}/aml_bt/sdio_driver_bt" "${BT_SRC}/kernel"; do
    [[ -d "${d}" ]] || die "missing source: ${d}"
done
[[ -f "${DTS}" ]] || die "missing DTS: ${DTS}"

rm -rf "${WORK}"
mkdir -p "${WORK}"/{dl,pkg,hdr,mods,dtb,build} "${OUT}"

# ------------------------------------------------------------------ 1. ophub package
log "Downloading ${SRC_REPO} ${SRC_TAG}/${KVER}.tar.gz"
curl -fL --retry 5 -o "${WORK}/dl/${KVER}.tar.gz" \
    "https://github.com/${SRC_REPO}/releases/download/${SRC_TAG}/${KVER}.tar.gz"
tar -xzf "${WORK}/dl/${KVER}.tar.gz" -C "${WORK}/pkg"
PKG="${WORK}/pkg/${KVER}"
(cd "${PKG}" && sha256sum -c sha256sums) || die "sha256 mismatch in the ophub package"

# ------------------------------------------------------------------ 2. headers
log "Preparing headers ${KREL}"
tar -xzf "${PKG}/header-${KREL}.tar.gz" -C "${WORK}/hdr"
HDR="${WORK}/hdr"
[[ -f "${HDR}/.config" && -f "${HDR}/Module.symvers" ]] || die "header package has no .config / Module.symvers"
# A kernel without SC2 pinctrl/clocks hangs at the vendor logo (kernel_s905x4/6.18.63 did).
for opt in CONFIG_PINCTRL_MESON_SC2 CONFIG_COMMON_CLK_SC2_PERIPHERALS CONFIG_COMMON_CLK_SC2_PLL; do
    grep -qx "${opt}=y" "${HDR}/.config" || die "${SRC_TAG}/${KVER} lacks ${opt}=y: it cannot boot on SC2"
done
# The ophub header package carries no host tools (fixdep, modpost); build them for x86_64.
find "${HDR}" -type f -exec touch {} +
"${MK[@]}" -C "${HDR}" olddefconfig >/dev/null
"${MK[@]}" -C "${HDR}" -s scripts
"${MK[@]}" -C "${HDR}" -s M=scripts/mod/ 2>/dev/null || true
VERMAGIC_HDR="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "${HDR}/include/generated/utsrelease.h")"
[[ "${VERMAGIC_HDR}" == "${KREL}" ]] || die "headers are for '${VERMAGIC_HDR}', expected '${KREL}'"

B="${WORK}/build"

# ------------------------------------------------------------------ 3. WiFi
log "WiFi: aml_sdio, vlsicomm ($(git -C "${WIFI_SRC}" rev-parse --short HEAD 2>/dev/null || echo local))"
cp -a "${WIFI_SRC}/project_w1" "${B}/wifi"
apply_patches wifi-amlogic-w1 "${B}/wifi" 2
"${MK[@]}" -C "${B}/wifi" driver KERNELDIR="${HDR}"
WIFI_SYMVERS="$(find "${B}/wifi" -name Module.symvers | head -1)"

# ------------------------------------------------------------------ 4. sdio_bt
log "BT: sdio_bt ($(git -C "${BT_SRC}" rev-parse --short HEAD 2>/dev/null || echo local))"
cp -a "${BT_SRC}/aml_bt/sdio_driver_bt" "${B}/sdio_bt"
apply_patches aml_bt "${B}/sdio_bt" 3
"${MK[@]}" -C "${HDR}" M="${B}/sdio_bt" KBUILD_EXTRA_SYMBOLS="${WIFI_SYMVERS}" modules

# ------------------------------------------------------------------ 5. hci_uart (W155S1)
log "BT: hci_uart from Linux v${KVER} + hci_aml-w155s1.patch"
mkdir -p "${B}/hci"
BT_TGZ="${WORK}/dl/bluetooth-v${KVER}.tar.gz"
curl -fsSL --retry 5 -o "${BT_TGZ}" \
    "https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux/+archive/refs/tags/v${KVER}/drivers/bluetooth.tar.gz"
tar -xzf "${BT_TGZ}" -C "${B}/hci"
patch -d "${B}/hci" -p3 --no-backup-if-mismatch < "${BT_SRC}/kernel/hci_aml-w155s1.patch"
# Keep only the hci_uart lines of the upstream Makefile; kbuild resolves the
# CONFIG_BT_HCIUART_* switches from the headers' auto.conf.
{ echo 'obj-m += hci_uart.o'; grep -E '^hci_uart-' "${B}/hci/Makefile"; } > "${B}/hci/Kbuild"
rm -f "${B}/hci/Makefile"
"${MK[@]}" -C "${HDR}" M="${B}/hci" modules

# ------------------------------------------------------------------ 6. front panel
# The FD6551 is driven by the tm16xx driver devmfc builds into its kernels
# (drivers/xtra/tm16xx, compatible devmfc,fd6551); the DTB targets it.
if tar -xzOf "${PKG}/modules-${KREL}.tar.gz" "${KREL}/modules.builtin" 2>/dev/null | grep -q "/tm16xx\.ko$"; then
    log "Front panel: built-in tm16xx found"
else
    echo "WARNING: ${SRC_TAG}/${KVER} has no built-in tm16xx: the front panel will stay dark" >&2
fi

# ------------------------------------------------------------------ 7. collect + verify
log "Collecting modules"
declare -A NEW_KO=(
    [aml_sdio]="$(find "${B}/wifi" -name aml_sdio.ko | head -1)"
    [vlsicomm]="$(find "${B}/wifi" -name vlsicomm.ko | head -1)"
    [sdio_bt]="${B}/sdio_bt/sdio_bt.ko"
    [hci_uart]="${B}/hci/hci_uart.ko"
)

for m in "${!NEW_KO[@]}"; do
    ko="${NEW_KO[$m]}"
    [[ -f "${ko}" ]] || die "module not built: ${m}"
    vm="$(modinfo -F vermagic "${ko}" | awk '{print $1}')"
    [[ "${vm}" == "${KREL}" ]] || die "${m}: vermagic '${vm}' != '${KREL}'"
    "${XC}strip" --strip-debug "${ko}"
done

# ------------------------------------------------------------------ 8. modules tarball
log "Repacking modules-${KREL}.tar.gz"
# depmod wants <base>/lib/modules/<krel>, so unpack straight into that layout
MODBASE="${WORK}/mods/lib/modules"
mkdir -p "${MODBASE}"
tar -xzf "${PKG}/modules-${KREL}.tar.gz" -C "${MODBASE}"
MODDIR="${MODBASE}/${KREL}"
[[ -d "${MODDIR}/kernel" ]] || die "unexpected modules layout"
declare -A DEFAULT_DIR=(
    [aml_sdio]=kernel/drivers/net/wireless/amlogic
    [vlsicomm]=kernel/drivers/net/wireless/amlogic
    [sdio_bt]=kernel/drivers/bluetooth
    [hci_uart]=kernel/drivers/bluetooth
)
for m in "${!NEW_KO[@]}"; do
    # Some packages keep vendor modules at the top of the modules dir (6.18.59),
    # others under kernel/ (6.18.63): replace every copy, keep the first location.
    mapfile -t found < <(find "${MODDIR}" -name "${m}.ko" | sort)
    dest="${found[0]:-${MODDIR}/${DEFAULT_DIR[$m]}/${m}.ko}"
    for extra in "${found[@]:1}"; do rm -f "${extra}"; echo "    ${m}: removed duplicate ${extra#${MODDIR}/}"; done
    mkdir -p "$(dirname "${dest}")"
    install -m 0644 "${NEW_KO[$m]}" "${dest}"
    printf '    %-12s -> %s%s\n' "${m}" "${dest#${MODDIR}/}" "${found[0]:+ (replaced)}"
done
tar -xzf "${PKG}/boot-${KREL}.tar.gz" -C "${WORK}" "./System.map-${KREL}"
depmod -b "${WORK}/mods" -F "${WORK}/System.map-${KREL}" -e "${KREL}"

# ------------------------------------------------------------------ 9. dtb tarball
log "Adding ${DTB_NAME} to dtb-amlogic-${KREL}.tar.gz"
tar -xzf "${PKG}/dtb-amlogic-${KREL}.tar.gz" -C "${WORK}/dtb"
dtc -q -I dts -O dtb -o "${WORK}/dtb/${DTB_NAME}" "${DTS}"

# ------------------------------------------------------------------ 10. bundle
log "Writing ${OUT}/${KVER}.tar.gz"
NEW="${WORK}/bundle/${KVER}"
mkdir -p "${NEW}"
cp "${PKG}/boot-${KREL}.tar.gz" "${PKG}/header-${KREL}.tar.gz" "${NEW}/"
TAROPT=(--owner=0 --group=0 --numeric-owner)
tar -czf "${NEW}/modules-${KREL}.tar.gz" "${TAROPT[@]}" -C "${MODBASE}" "${KREL}"
tar -czf "${NEW}/dtb-amlogic-${KREL}.tar.gz" "${TAROPT[@]}" -C "${WORK}/dtb" .
(cd "${NEW}" && sha256sum boot-* dtb-amlogic-* header-* modules-* > sha256sums)
cat > "${NEW}/BUILDINFO" <<EOF
kernel        ${SRC_REPO} ${SRC_TAG} ${KVER}
wifi          $(git -C "${WIFI_SRC}" describe --always --dirty 2>/dev/null || echo local)
aml_bt        $(git -C "${BT_SRC}" describe --always --dirty 2>/dev/null || echo local)
magicsee      $(git -C "${REPO_ROOT}" describe --always --dirty 2>/dev/null || echo local)
built         $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
tar -czf "${OUT}/${KVER}.tar.gz" "${TAROPT[@]}" -C "${WORK}/bundle" "${KVER}"

log "Done"
cat "${NEW}/BUILDINFO"
echo
echo "Bundle : ${OUT}/${KVER}.tar.gz"
echo "Local  : cp -r ${NEW} <amlogic-armbian>/build-armbian/kernel/magicsee/  (rebuild reuses local kernels)"
echo "Publish: gh release upload kernel_magicsee ${OUT}/${KVER}.tar.gz --repo <owner>/amlogic-s9xxx-armbian --clobber"

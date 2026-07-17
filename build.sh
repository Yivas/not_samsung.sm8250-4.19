#!/usr/bin/env bash
set -euo pipefail

: "${DEVICE:?DEVICE must be set}"
[ "$DEVICE" = "r8q" ] || {
    echo "Only DEVICE=r8q is supported" >&2
    exit 2
}

SECONDS=0 # builtin bash timer

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===== AnyKernel3 =====
AK3_REPO="https://github.com/skye-tachyon/AnyKernel3"
AK3_COMMIT="04ed56d456f311557f1633b2d67dc5d193b7a59b"

PROFILE="${SUSFS_PROFILE:-safe}"
SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
BUILD_DATE="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y%m%d')"
ZIPNAME="YivasKernel-$DEVICE-SUSFS-v2-$PROFILE-$BUILD_DATE.zip"
TC_DIR="$(pwd)/tc/clang"
TC_ARCHIVE="llvm-22.1.8-x86_64.tar.gz"
TC_SHA256="1751f120b447f85492b9721212bb7802a7d400b95a55ba266219ba0c542d1c58"
SUSFS_CONFIG="vendor/not/susfs.config"
if [ "$PROFILE" = "full" ]; then
    SUSFS_CONFIG="vendor/not/susfs-full.config"
elif [ "$PROFILE" != "safe" ]; then
    echo "Unknown SUSFS_PROFILE: $PROFILE" >&2
    exit 2
fi
DEFCONFIG="vendor/kona-perf_defconfig vendor/samsung/kona-sec-common.config vendor/samsung/$DEVICE.config vendor/not/ksu.config $SUSFS_CONFIG"

OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"

if test -z "$(git rev-parse --show-cdup 2>/dev/null)" &&
   head=$(git rev-parse --verify HEAD 2>/dev/null); then
    ZIPNAME="${ZIPNAME::-4}-${head:0:8}.zip"
fi

export KBUILD_BUILD_TIMESTAMP="$(git show -s --format=%cD HEAD)"
export KBUILD_BUILD_USER="yivas"
export KBUILD_BUILD_HOST="github-actions"
export KBUILD_BUILD_VERSION=1

git submodule update --init --recursive

export PATH="$TC_DIR/bin:$PATH"

if ! [ -d "$TC_DIR" ]; then
    echo -e "${YELLOW}Clang not found. Fetching verified archive...${NC}"
    mkdir -p "$TC_DIR"
    curl -fL --retry 3 -o "$TC_ARCHIVE" \
        "https://www.kernel.org/pub/tools/llvm/files/$TC_ARCHIVE"
    echo "$TC_SHA256  $TC_ARCHIVE" | sha256sum -c -
    tar -xzf "$TC_ARCHIVE" -C "$TC_DIR" --strip-components=1
    rm -f "$TC_ARCHIVE"
fi

mkdir -p out
echo -e "${YELLOW}building with: $DEFCONFIG${NC}"

make O=out ARCH=arm64 $DEFCONFIG
make O=out ARCH=arm64 olddefconfig

grep -qx 'CONFIG_KSU=y' out/.config
grep -qx 'CONFIG_KSU_SUSFS=y' out/.config
grep -qx 'CONFIG_KSU_SUSFS_SUS_PATH=y' out/.config
if [ "$PROFILE" = "full" ]; then
    grep -qx 'CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y' out/.config
else
    grep -qx '# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set' out/.config
fi

echo -e "\n${YELLOW}Starting compilation...${NC}\n"

make -j$(nproc --all) O=out ARCH=arm64 \
    CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    LLVM=1 LLVM_IAS=1 Image

if [ -f "$BOOT_DIR/Image" ]; then
    echo -e "${GREEN}Kernel Image found!${NC}"
else
    echo -e "\n${RED}Compilation failed! Image not found.${NC}"
    exit 1
fi

rm -rf AnyKernel3
echo "[*] Fetching pinned AnyKernel3 $AK3_COMMIT"
git init -q AnyKernel3
git -C AnyKernel3 fetch -q --depth=1 "$AK3_REPO" "$AK3_COMMIT"
git -C AnyKernel3 checkout -q --detach FETCH_HEAD

echo -e "Preparing zip...\n"

cp "$BOOT_DIR/Image" AnyKernel3/Image
cp packaging/anykernel.sh AnyKernel3/anykernel.sh
find AnyKernel3 -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

cd AnyKernel3

find . -type f -not -path './.git/*' -not -name README.md \
	-not -name '*placeholder' -printf '%P\n' | LC_ALL=C sort | \
    zip -X -9 "../$ZIPNAME" -@
cd ..

echo -e "\n${GREEN}Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!${NC}"
echo -e "${GREEN}Zip: $ZIPNAME${NC}"

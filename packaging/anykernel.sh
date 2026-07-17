### AnyKernel3 Ramdisk Mod Script
## boot-only package for Samsung SM-G781B / r8q

properties() { '
kernel.string=YivasKernel r8q SUSFS v2
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=r8q
device.name2=r8qxx
device.name3=r8qxxx
supported.versions=11 - 17
supported.patchlevels=
supported.vendorpatchlevels=
'; }

boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
}

BLOCK=/dev/block/platform/soc/1d84000.ufshc/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=0;
NO_MAGISK_CHECK=1;

. tools/ak3-core.sh;

split_boot;
flash_boot;

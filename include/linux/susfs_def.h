#ifndef KSU_SUSFS_DEF_H
#define KSU_SUSFS_DEF_H

#include <linux/bits.h>

/* shared with userspace ksu_susfs tool */
#define CMD_SUSFS_ADD_SUS_PATH 0x55550
#define CMD_SUSFS_SHOW_VERSION 0x555e1
#define CMD_SUSFS_SHOW_ENABLED_FEATURES 0x555e2
#define CMD_SUSFS_SHOW_VARIANT 0x555e3

#define SUSFS_MAX_LEN_PATHNAME 256
#define INODE_STATE_SUS_PATH BIT(24)

#endif /* KSU_SUSFS_DEF_H */

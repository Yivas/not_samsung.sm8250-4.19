#ifndef KSU_SUSFS_H
#define KSU_SUSFS_H

#include <linux/susfs_def.h>
#include <linux/types.h>
#include <linux/version.h>

#define SUSFS_VERSION "v1.5.5"
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#define SUSFS_VARIANT "NON-GKI"
#else
#define SUSFS_VARIANT "GKI"
#endif

struct inode;

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
struct st_susfs_sus_path {
	unsigned long target_ino;
	char target_pathname[SUSFS_MAX_LEN_PATHNAME];
};

int susfs_add_sus_path(struct st_susfs_sus_path __user *user_info);
bool susfs_should_hide_inode(struct inode *inode);
bool susfs_should_hide_dirent(dev_t dev, unsigned long ino);
#endif

#endif

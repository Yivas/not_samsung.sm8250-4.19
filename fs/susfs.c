#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/hashtable.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs.h>
#include <linux/uaccess.h>

#define SUSFS_PER_USER_RANGE 100000
#define SUSFS_FIRST_APPLICATION_UID 10000
#define SUSFS_LAST_APPLICATION_UID 19999
#define SUSFS_FIRST_APP_ZYGOTE_ISOLATED_UID 90000
#define SUSFS_LAST_ISOLATED_UID 99999

extern bool __ksu_is_allow_uid(uid_t uid);

struct st_susfs_sus_path_hlist {
	dev_t target_dev;
	unsigned long target_ino;
	char target_pathname[SUSFS_MAX_LEN_PATHNAME];
	struct path target_path;
	struct hlist_node node;
};

static DEFINE_HASHTABLE(sus_path_hlist, 10);
static DEFINE_MUTEX(sus_path_update_lock);

static bool susfs_is_sus_path(dev_t dev, unsigned long ino)
{
	struct st_susfs_sus_path_hlist *entry;
	bool found = false;

	rcu_read_lock();
	hash_for_each_possible_rcu(sus_path_hlist, entry, node, ino) {
		if (entry->target_dev == dev && entry->target_ino == ino) {
			found = true;
			break;
		}
	}
	rcu_read_unlock();

	return found;
}

static bool susfs_should_hide_for_current(void)
{
	uid_t uid = current_uid().val;
	uid_t appid = uid % SUSFS_PER_USER_RANGE;

	if ((appid < SUSFS_FIRST_APPLICATION_UID ||
	     appid > SUSFS_LAST_APPLICATION_UID) &&
	    (appid < SUSFS_FIRST_APP_ZYGOTE_ISOLATED_UID ||
	     appid > SUSFS_LAST_ISOLATED_UID))
		return false;

	return !__ksu_is_allow_uid(uid);
}

bool susfs_should_hide_inode(struct inode *inode)
{
	if (!inode ||
	    !(READ_ONCE(inode->i_state) & INODE_STATE_SUS_PATH) ||
	    !susfs_should_hide_for_current())
		return false;

	return susfs_is_sus_path(inode->i_sb->s_dev, inode->i_ino);
}

bool susfs_should_hide_dirent(dev_t dev, unsigned long ino)
{
	return susfs_is_sus_path(dev, ino) && susfs_should_hide_for_current();
}

int susfs_add_sus_path(struct st_susfs_sus_path __user *user_info)
{
	struct st_susfs_sus_path_hlist *entry;
	struct st_susfs_sus_path_hlist *new_entry;
	struct st_susfs_sus_path_hlist *old_entry = NULL;
	struct st_susfs_sus_path info;
	struct inode *inode;
	struct path path;
	const char *fs_type;
	size_t path_len;
	int bkt;
	int error;

	if (copy_from_user(&info, user_info, sizeof(info)))
		return -EFAULT;

	path_len = strnlen(info.target_pathname, sizeof(info.target_pathname));
	if (path_len < 2 || path_len == sizeof(info.target_pathname) ||
	    info.target_pathname[0] != '/')
		return -EINVAL;

	error = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);
	if (error)
		return error;

	fs_type = path.mnt->mnt_sb->s_type->name;
	if (!strcmp(fs_type, "tmpfs") || !strcmp(fs_type, "fuse")) {
		error = -EOPNOTSUPP;
		goto out_path;
	}

	inode = d_inode(path.dentry);
	if (!inode) {
		error = -ENOENT;
		goto out_path;
	}

	new_entry = kzalloc(sizeof(*new_entry), GFP_KERNEL);
	if (!new_entry) {
		error = -ENOMEM;
		goto out_path;
	}

	new_entry->target_dev = inode->i_sb->s_dev;
	new_entry->target_ino = inode->i_ino;
	new_entry->target_path = path;
	path_get(&new_entry->target_path);
	strscpy(new_entry->target_pathname, info.target_pathname,
		sizeof(new_entry->target_pathname));

	spin_lock(&inode->i_lock);
	inode->i_state |= INODE_STATE_SUS_PATH;
	spin_unlock(&inode->i_lock);

	mutex_lock(&sus_path_update_lock);
	hash_for_each(sus_path_hlist, bkt, entry, node) {
		if (!strcmp(entry->target_pathname,
			    new_entry->target_pathname)) {
			old_entry = entry;
			break;
		}
	}

	hash_add_rcu(sus_path_hlist, &new_entry->node,
		     new_entry->target_ino);
	if (old_entry)
		hash_del_rcu(&old_entry->node);
	mutex_unlock(&sus_path_update_lock);

	if (old_entry) {
		synchronize_rcu();
		path_put(&old_entry->target_path);
		kfree(old_entry);
	}

	error = 0;
out_path:
	path_put(&path);
	return error;
}

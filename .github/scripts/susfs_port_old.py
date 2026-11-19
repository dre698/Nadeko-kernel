import pathlib, sys
ok_all = True
def sub(path, old, new, label, expect=1):
    global ok_all
    p = pathlib.Path(path); t = p.read_text()
    c = t.count(old)
    if c != expect:
        print(f"[old-port] FAILED {label}: {c} matches (expected {expect})"); ok_all = False; return
    p.write_text(t.replace(old, new)); print(f"[old-port] ok {label}")

C = "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_SUS_KSTAT)"
E = "#endif // " + C

# fs/readdir.c: old_readdir + compat old_readdir
head = "\t\t.ctx.actor = {a},\n\t\t.dirent = dirent\n\t};\n\n\tif (!f.file)\n\t\treturn -EBADF;\n\terror = iterate_dir(f.file, &buf.ctx);\n\tif (buf.result)\n\t\terror = buf.result;\n\n\tfdput_pos(f);\n\treturn error;\n}\n"
for a in ("fillonedir", "compat_fillonedir"):
    new = ("\t\t.ctx.actor = %s,\n\t\t.dirent = dirent\n\t};\n"
           "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tstruct path susfs_path;\n\tbool susfs_pinned = false;\n#endif\n\n"
           "\tif (!f.file)\n\t\treturn -EBADF;\n"
           "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tsusfs_readdir_sb(f.file, &buf.sb, &susfs_path, &susfs_pinned);\n#endif\n"
           "\terror = iterate_dir(f.file, &buf.ctx);\n\tif (buf.result)\n\t\terror = buf.result;\n\n\tfdput_pos(f);\n"
           "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\tif (susfs_pinned)\n\t\tpath_put(&susfs_path);\n#endif\n\treturn error;\n}\n") % a
    sub("fs/readdir.c", head.replace("{a}", a), new, f"readdir {a}")

# fs/statfs.c
helper = '''#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
/* Expose the VFS helpers needed by the 2.3.0 SUS_KSTAT implementation. */
int statfs_by_dentry_wrapper(struct dentry *dentry, struct kstatfs *buf)
{
	return statfs_by_dentry(dentry, buf);
}

int calculate_f_flags_wrapper(struct vfsmount *mnt)
{
	return calculate_f_flags(mnt);
}

static int susfs_statfs_by_dentry(struct dentry *dentry, struct vfsmount *mnt,
				 struct kstatfs *buf, bool *is_fuse)
{
	int ret;

	if (!dentry->d_sb->s_op->statfs)
		return -ENOSYS;
	memset(buf, 0, sizeof(*buf));
	ret = security_sb_statfs(dentry);
	if (ret)
		return ret;
	if (!susfs_sus_kstat_spoof_vfs_statfs(d_backing_inode(dentry), buf,
					   is_fuse)) {
		if (!buf->f_frsize)
			buf->f_frsize = buf->f_bsize;
		return 0;
	}
	ret = dentry->d_sb->s_op->statfs(dentry, buf);
	if (!ret) {
		buf->f_flags = calculate_f_flags(mnt);
		if (!buf->f_frsize)
			buf->f_frsize = buf->f_bsize;
	}
	return ret;
}
#endif

'''
body = '''#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	if (susfs_is_current_app_uid()) {
		struct inode *inode = d_backing_inode(path->dentry);
		bool is_fuse = false;
		if (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
			// - here we do not call calculate_f_flags() here as buf->f_flags on the
			//   sus_kstat path will be handled by susfs_statfs_by_dentry().
			return susfs_statfs_by_dentry(path->dentry, path->mnt, buf, &is_fuse);
		}
	}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (likely(susfs_is_current_proc_umounted())) {
		struct vfsmount *no_sus_vfsmnt = NULL;
		no_sus_vfsmnt = susfs_get_non_sus_vfsmnt_from_vfsmnt(path->mnt);
		if (path->mnt == no_sus_vfsmnt) {
			dput(no_sus_vfsmnt->mnt_root);
			mntput(no_sus_vfsmnt);
			error = statfs_by_dentry(path->dentry, buf);
			if (!error)
				buf->f_flags = calculate_f_flags(path->mnt);
			return error;
		}
		error = statfs_by_dentry(no_sus_vfsmnt->mnt_root, buf);
		if (!error)
			buf->f_flags = calculate_f_flags(no_sus_vfsmnt);
		dput(no_sus_vfsmnt->mnt_root);
		mntput(no_sus_vfsmnt);
		return error;
	}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT

'''
sub("fs/statfs.c",
    "int vfs_statfs(const struct path *path, struct kstatfs *buf)\n{\n    int error;\n    error = statfs_by_dentry",
    helper + "int vfs_statfs(const struct path *path, struct kstatfs *buf)\n{\n    int error;\n\n" + body + "    error = statfs_by_dentry",
    "statfs vfs_statfs")

# fs/namespace.c
sub("fs/namespace.c",
    '#include <linux/sched/task.h>\n\n#include "pnode.h"\n#include "internal.h"\n',
    '#include <linux/sched/task.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n\n#include "pnode.h"\n#include "internal.h"\n\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif\n\n',
    "namespace includes/externs")
sub("fs/namespace.c",
    "    mnt = alloc_vfsmnt(name);\n    if (!mnt)\n        return ERR_PTR(-ENOMEM);\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted) &&\n\t    susfs_is_current_ksu_domain())\n\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(name);\n\telse\n#endif\n\t\tmnt = alloc_vfsmnt(name);\n    if (!mnt)\n        return ERR_PTR(-ENOMEM);\n",
    "namespace vfs_kern_mount alloc")

# fs/notify/fdinfo.c
sub("fs/notify/fdinfo.c",
    "static void show_fdinfo(struct seq_file *m, struct file *f,\n               void (*show)(struct seq_file *m,\n                    struct fsnotify_mark *mark))\n{",
    "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\nextern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);\nextern void susfs_sus_kstat_spoof_inotify_fdinfo(unsigned long *out_target_ino, dev_t *out_target_dev);\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\n"
    + C + "\nstatic void show_fdinfo(struct seq_file *m, struct file *f,\n\t\t\tvoid (*show)(struct seq_file *m,\n\t\t\t\t     struct fsnotify_mark *mark,\n\t\t\t\t     struct file *file))\n#else\nstatic void show_fdinfo(struct seq_file *m, struct file *f,\n\t\t\tvoid (*show)(struct seq_file *m,\n\t\t\t\t     struct fsnotify_mark *mark))\n" + E + "\n{",
    "fdinfo show_fdinfo signature")
sub("fs/notify/fdinfo.c", "\t\tshow(m, mark);\n",
    C + "\n\t\tshow(m, mark, f);\n#else\n\t\tshow(m, mark);\n" + E + "\n", "fdinfo show() call")
sub("fs/notify/fdinfo.c",
    "static void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)\n{",
    C + "\nstatic void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark, struct file *file)\n#else\nstatic void fanotify_fdinfo(struct seq_file *m, struct fsnotify_mark *mark)\n" + E + "\n{",
    "fdinfo fanotify_fdinfo signature")

# fs/proc/fd.c
sub("fs/proc/fd.c",
    '#include <linux/proc_fs.h>\n#include "../mount.h"\n#include "internal.h"\n#include "fd.h"\n',
    '#include <linux/proc_fs.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS\n#include "../mount.h"\n#include "internal.h"\n#include "fd.h"\n\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern int susfs_get_non_sus_mnt_id_from_mnt(struct mount *orig_mnt);\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
    '#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\nextern bool susfs_is_inode_sus_kstat(struct inode *inode, bool *out_is_fuse);\nextern void susfs_sus_kstat_spoof_proc_fd_seq_show(int *out_target_mnt_id, unsigned long *out_target_ino, dev_t target_dev);\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\n',
    "fd.c includes/externs")

# fs/proc/task_mmu.c
sub("fs/proc/task_mmu.c",
    "\t\tstruct inode *inode = file_inode(vma->vm_file);\n        dev = inode->i_sb->s_dev;\n        ino = inode->i_ino;\n        pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n\t}\n",
    "\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n\t\tif (SUSFS_IS_INODE_OPEN_REDIRECT(inode)) {\n\t\t\tchar *spoofed_redirected_name = NULL;\n\t\t\tint srcu_idx = srcu_read_lock(&susfs_srcu_open_redirect);\n\t\t\tint ret = susfs_open_redirect_spoof_show_map_vma_srcu(inode, &ino, &dev, &spoofed_redirected_name);\n\t\t\tif (!ret) {\n\t\t\t\tpgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n\t\t\t\tstart = vma->vm_start;\n\t\t\t\tend = vma->vm_end;\n\t\t\t\tshow_vma_header_prefix(m, start, end, flags, pgoff, dev, ino);\n\t\t\t\tseq_pad(m, ' ');\n\t\t\t\tif (spoofed_redirected_name)\n\t\t\t\t\tseq_puts(m, spoofed_redirected_name);\n\t\t\t\tseq_putc(m, '\\n');\n\t\t\t\tsrcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);\n\t\t\t\treturn;\n\t\t\t}\n\t\t\tsrcu_read_unlock(&susfs_srcu_open_redirect, srcu_idx);\n\t\t}\n#endif // #ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tif (SUSFS_IS_INODE_SUS_MAP(inode))\n\t\t\treturn;\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "        dev = inode->i_sb->s_dev;\n        ino = inode->i_ino;\n        pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\t\tsusfs_sus_kstat_spoof_show_map_vma(inode, &dev, &ino);\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n\t}\n",
    "task_mmu show_map_vma")
sub("fs/proc/task_mmu.c",
    "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\t\tvma = find_vma(mm, start_vaddr);\n\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\tgoto bypass_orig_flow;\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\nbypass_orig_flow:\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tup_read(&mm->mmap_sem);\n\t\tstart_vaddr = end;\n",
    "task_mmu pagemap_read")

# kernel/sys.c: the patch lands the spoof_uname hook AFTER newuname's closing brace on this base
# (different function layout), i.e. outside any function. Remove it and put it before up_read().
HOOK = ("#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
        "\tif (static_branch_likely(&susfs_is_uname_spoof_buffer_set))\n"
        "\t\tsusfs_spoof_uname(&tmp);\n"
        "#endif\n")
sub("kernel/sys.c", "\treturn 0;\n}\n" + HOOK + "\n#ifdef __ARCH_WANT_SYS_OLD_UNAME",
    "\treturn 0;\n}\n\n#ifdef __ARCH_WANT_SYS_OLD_UNAME", "sys.c remove stray spoof_uname hook")
sub("kernel/sys.c", "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n{\n\tstruct new_utsname tmp;\n\n\tdown_read(&uts_sem);\n\tmemcpy(&tmp, utsname(), sizeof(tmp));\n\tup_read(&uts_sem);",
    "SYSCALL_DEFINE1(newuname, struct new_utsname __user *, name)\n{\n\tstruct new_utsname tmp;\n\n\tdown_read(&uts_sem);\n\tmemcpy(&tmp, utsname(), sizeof(tmp));\n" + HOOK + "\tup_read(&uts_sem);",
    "sys.c newuname spoof_uname hook before up_read")

# the old base's pagemap_read is already handled above, so drop the stale rejects it leaves behind
for rej in ("fs/proc/task_mmu.c.rej", "fs/readdir.c.rej", "fs/statfs.c.rej", "fs/namespace.c.rej", "fs/notify/fdinfo.c.rej", "fs/proc/fd.c.rej"):
    pathlib.Path(rej).unlink(missing_ok=True)
sys.exit(0 if ok_all else 1)

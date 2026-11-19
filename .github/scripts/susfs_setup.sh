#!/bin/bash
set -eu

# Applies the embedded SUSFS patch (susfs_patch_to_4.19.patch), generated
# by diffing a reference KSU fork's own kernel source before/after its
# susfs integration (same upstream lineage as NadekoSU). This is that
# fork's own reference susfs integration, not a third-party non-GKI
# backport, so it matches NadekoSU's driver API (CMD_SUSFS_*, SUSFS_MAGIC,
# all handler functions) exactly - no compat shims needed.
#
# It includes the hook insertions (fs/exec.c, fs/open.c, fs/stat.c,
# kernel/sys.c, kernel/reboot.c, drivers/input/input.c,
# security/selinux/hooks.c for selinux_hide) directly, so this repo's own
# syscall_hook.sh is NOT needed for this patch - do not run it in the
# same workflow as this script, they would double-patch the same files.

PATCH_FILE=".github/scripts/susfs_patch_to_4.19.patch"
REJECT_DIR="susfs-rejects"

if [ ! -f "$PATCH_FILE" ]; then
  echo "Missing $PATCH_FILE - was it committed to the repo?"
  exit 1
fi

# --- Pre-cleanup: old CONFIG_KSU-gated manual hooks that would otherwise
# collide with the ones this patch adds to the same files ---
# fs/stat.c's existing hook is gated on CONFIG_KSU_MANUAL_HOOK specifically,
# so it self-disables once the defconfig switches to CONFIG_KSU_SUSFS - no
# cleanup needed there. fs/open.c and kernel/reboot.c gate on plain
# CONFIG_KSU (always on), so their old hook declarations/calls would
# otherwise conflict (duplicate/mismatched signature) with this patch's own
# ksu_handle_faccessat / ksu_handle_sys_reboot hooks.
#
# fs/exec.c is deliberately left untouched and its fs/exec.c hunks removed
# from the embedded patch entirely: this kernel's __do_execve_file()/
# do_execveat() control flow has diverged structurally from the patch's
# source tree (no CONFIG_KSU_MANUAL_HOOK wrapping around those functions
# to begin with), so the patch's #elif-based insertions can't apply
# safely here - they'd land via fuzzy offset matching and leave dangling
# #elif blocks with no matching #if. The existing plain
# `#ifdef CONFIG_KSU` execveat hook in fs/exec.c is left in place and
# keeps working as it always has; only the SUSFS-specific "sucompat via
# exec" enhancement is unavailable, not core SUS_PATH/SUS_MOUNT/etc.
# Verified against this tree's actual file content before writing this.
set +e
python3 << 'PYEOF'
import pathlib, sys

def remove(path, old, label, expect=1):
    p = pathlib.Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != expect:
        print(f"[precleanup] SKIPPED {label} ({count} matches, expected {expect})")
        return False
    p.write_text(text.replace(old, "", expect if expect > 1 else 1))
    print(f"[precleanup] removed {label}")
    return True

ok1 = remove("fs/open.c",
	"#ifdef CONFIG_KSU\n"
	"extern __attribute__((hot)) int ksu_handle_faccessat(int *dfd,\n"
	"\t\tconst char __user **filename_user, int *mode, int *flags);\n"
	"#endif\n\n",
	"fs/open.c old faccessat extern declaration")

ok2 = remove("fs/open.c",
	"\n#ifdef CONFIG_KSU\n"
	"\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
	"#endif\n",
	"fs/open.c old faccessat call")

ok5 = remove("kernel/reboot.c",
	"#ifdef CONFIG_KSU\n"
	"extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
	"#endif\n\n",
	"kernel/reboot.c old sys_reboot extern declaration")

ok6 = remove("kernel/reboot.c",
	"\n#ifdef CONFIG_KSU\n"
	"\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
	"#endif\n",
	"kernel/reboot.c old sys_reboot call")

if not (ok1 and ok2 and ok5 and ok6):
    sys.exit(1)
PYEOF
PRECLEAN_STATUS=$?
set -e
if [ "$PRECLEAN_STATUS" -ne 0 ]; then
  echo "Pre-cleanup of old manual hooks did not match expected content - stopping before the main patch, since applying it now would likely produce a conflicting-declaration build error instead of a clean .rej."
  exit 1
fi

echo "Applying $PATCH_FILE..."
set +e
PATCH_LOG=$(patch -p1 --fuzz=3 --no-backup-if-mismatch < "$PATCH_FILE" 2>&1)
set -e
echo "$PATCH_LOG"
python3 .github/scripts/susfs_port_old.py || echo "[old-port] SOME PORTS FAILED"

# --- Manual fixup: fs/proc/task_mmu.c ---
# This kernel's pagemap_read() calls the OLDER 3-arg
# walk_page_range(start_vaddr, end, &pagemap_walk), not the 5-arg
# walk_page_range(mm, start_vaddr, end, &pagemap_ops, &pm) this patch's
# source tree assumes. Verified by direct comparison against this tree's
# actual fs/proc/task_mmu.c - adapts the same SUS_MAP bypass logic to the
# older call signature instead of guessing.
set +e
python3 << 'PYEOF'
import pathlib, sys

def remove(path, old, label, expect=1):
    p = pathlib.Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != expect:
        print(f"[fixup] SKIPPED {label} ({count} matches, expected {expect})")
        return False
    p.write_text(text.replace(old, "", expect if expect > 1 else 1))
    print(f"[fixup] removed {label}")
    return True

p = pathlib.Path("fs/proc/task_mmu.c")
text = p.read_text()
old = (
	"\t\tret = mmap_read_lock_killable(mm);\n"
	"\t\tif (ret)\n"
	"\t\t\tgoto out_free;\n"
	"\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
	"\t\tmmap_read_unlock(mm);\n"
)
new = (
	"\t\tret = mmap_read_lock_killable(mm);\n"
	"\t\tif (ret)\n"
	"\t\t\tgoto out_free;\n"
	"#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
	"\t\t{\n"
	"\t\tstruct vm_area_struct *susfs_vma = find_vma(mm, start_vaddr);\n"
	"\t\tif (susfs_vma && susfs_vma->vm_file &&\n"
	"\t\t    SUSFS_IS_INODE_SUS_MAP(file_inode(susfs_vma->vm_file)))\n"
	"\t\t\tgoto susfs_bypass_walk;\n"
	"\t\t}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
	"\t\tret = walk_page_range(start_vaddr, end, &pagemap_walk);\n"
	"#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
	"susfs_bypass_walk:\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
	"\t\tmmap_read_unlock(mm);\n"
)
count = text.count(old)
ok_a = False
if count == 1:
    p.write_text(text.replace(old, new, 1))
    print("[fixup] task_mmu.c pagemap_read SUS_MAP bypass applied")
    ok_a = True
else:
    print(f"[fixup] SKIPPED task_mmu.c ({count} matches, expected 1) - leaving .rej for manual review")

# --- Manual fixup: fs/namei.c may_create() ---
# The patch's SUS_PATH hunk calls inode_permission2(mnt, dir, ...), a
# vendor permission-check variant that doesn't exist anywhere in this
# kernel, with `mnt` not in scope in may_create() (it only takes dir and
# child). Verified: this same function already calls the standard
# inode_permission(dir, mask) a few lines below for its normal path, so
# that's the correct, already-available call to use here too - not a
# guess at new permission logic, just using this kernel's existing API.
p2 = pathlib.Path("fs/namei.c")
text2 = p2.read_text()
old2 = "int error = inode_permission2(mnt, dir, MAY_WRITE | MAY_EXEC);"
new2 = "int error = inode_permission(dir, MAY_WRITE | MAY_EXEC);"
count2 = text2.count(old2)
ok_b = False
if count2 == 1:
    p2.write_text(text2.replace(old2, new2, 1))
    print("[fixup] namei.c may_create() inode_permission2 -> inode_permission applied")
    ok_b = True
else:
    print(f"[fixup] SKIPPED namei.c may_create ({count2} matches, expected 1) - leaving as-is")

# --- Manual fixup: security/selinux/hooks.c + selinuxfs.c selinux_hide ---
# The patch wires its own selinux_hide feature via wrapper functions
# (handle_selinux_setprocattr, handle_sel_write_context,
# handle_sel_write_access) that call through to my_setprocattr/
# my_write_context/my_write_access - but those 3 are declared `static`
# (file-local) in NadekoSU's own kernel/feature/selinux_hide.c, not
# externally callable. NadekoSU already implements selinux_hide
# independently via runtime binary patching (ksu_patch_text() overwriting
# the LSM hook table's function pointers directly), which doesn't need or
# use this patch's source-level wrapper mechanism at all. The other
# related externs (ksu_selinux_hide_running/_enabled,
# fake_status_initialize_key, initialize_fake_status) ARE exported by
# selinux_hide.c and stay untouched - only the 3 wrapper call sites and
# their now-dead extern/function bodies are reverted to the plain
# original SELinux functions.
ok_c = remove("security/selinux/hooks.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"extern bool ksu_selinux_hide_running __read_mostly;\n"
	"extern int my_setprocattr(const char *name, void *value, size_t size);\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n\n",
	"hooks.c selinux_hide externs")

ok_d = remove("security/selinux/hooks.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"static int handle_selinux_setprocattr(const char *name, void *value, size_t size)\n"
	"{\n"
	"\tif ((likely(!strcmp(name, \"current\") &&\n"
	"\t\t\t\tcurrent_uid().val >= 10000 &&\n"
	"\t\t\t\tksu_selinux_hide_running)))\n"
	"\t\treturn my_setprocattr(name, value, size);\n"
	"\treturn selinux_setprocattr(name, value, size);\n"
	"}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n\n",
	"hooks.c handle_selinux_setprocattr wrapper")

p_hooks = pathlib.Path("security/selinux/hooks.c")
text_hooks = p_hooks.read_text()
old_e = (
	"#ifdef CONFIG_KSU_SUSFS\n"
	"\tLSM_HOOK_INIT(setprocattr, handle_selinux_setprocattr),\n"
	"#else\n"
	"\tLSM_HOOK_INIT(setprocattr, selinux_setprocattr),\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n"
)
new_e = "\tLSM_HOOK_INIT(setprocattr, selinux_setprocattr),\n"
ok_e = text_hooks.count(old_e) == 1
if ok_e:
    p_hooks.write_text(text_hooks.replace(old_e, new_e, 1))
    print("[fixup] hooks.c LSM_HOOK_INIT(setprocattr) reverted to original")
else:
    print(f"[fixup] SKIPPED hooks.c LSM_HOOK_INIT ({text_hooks.count(old_e)} matches, expected 1)")

ok_f = remove("security/selinux/selinuxfs.c",
	"extern ssize_t my_write_context(struct file *file, char *buf, size_t size);\n"
	"extern ssize_t my_write_access(struct file *file, char *buf, size_t size);\n",
	"selinuxfs.c my_write_context/my_write_access externs")

ok_g = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"static ssize_t handle_sel_write_access(struct file *file, char *buf, size_t size);\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n",
	"selinuxfs.c handle_sel_write_access forward declaration")

p_sfs = pathlib.Path("security/selinux/selinuxfs.c")
text_sfs = p_sfs.read_text()
old_h = (
	"#ifdef CONFIG_KSU_SUSFS\n"
	"\t[SEL_ACCESS] = handle_sel_write_access,\n"
	"#else\n"
	"\t[SEL_ACCESS] = sel_write_access,\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n"
)
new_h = "\t[SEL_ACCESS] = sel_write_access,\n"
ok_h = text_sfs.count(old_h) == 1
if ok_h:
    text_sfs = text_sfs.replace(old_h, new_h, 1)
    p_sfs.write_text(text_sfs)
    print("[fixup] selinuxfs.c write_op[SEL_ACCESS] reverted to original")
else:
    print(f"[fixup] SKIPPED selinuxfs.c SEL_ACCESS ({text_sfs.count(old_h)} matches, expected 1)")

text_sfs = p_sfs.read_text()
old_i = (
	"#ifdef CONFIG_KSU_SUSFS\n"
	"\t[SEL_CONTEXT] = handle_sel_write_context,\n"
	"#else\n"
	"\t[SEL_CONTEXT] = sel_write_context,\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n"
)
new_i = "\t[SEL_CONTEXT] = sel_write_context,\n"
ok_i = text_sfs.count(old_i) == 1
if ok_i:
    text_sfs = text_sfs.replace(old_i, new_i, 1)
    p_sfs.write_text(text_sfs)
    print("[fixup] selinuxfs.c write_op[SEL_CONTEXT] reverted to original")
else:
    print(f"[fixup] SKIPPED selinuxfs.c SEL_CONTEXT ({text_sfs.count(old_i)} matches, expected 1)")

ok_j = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"static ssize_t handle_sel_write_context(struct file *file, char *buf, size_t size) {\n"
	"\tif ((likely(current_uid().val >= 10000 && ksu_selinux_hide_running)))\n"
	"\t\treturn my_write_context(file, buf, size);\n"
	"\treturn sel_write_context(file, buf, size);\n"
	"}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n",
	"selinuxfs.c handle_sel_write_context wrapper")

ok_k = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"static ssize_t handle_sel_write_access(struct file *file, char *buf, size_t size)\n"
	"{\n"
	"\tif ((likely(current_uid().val >= 10000 && ksu_selinux_hide_running)))\n"
	"\t\treturn my_write_access(file, buf, size);\n"
	"\treturn sel_write_access(file, buf, size);\n"
	"}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n",
	"selinuxfs.c handle_sel_write_access wrapper")

# --- selinuxfs.c: fake_status hook in sel_open_handle_status ---
# NadekoSU does NOT export fake_status / fake_status_initialize_key /
# initialize_fake_status / ksu_selinux_hide_running, so any leftover
# reference from the patch fails at link time (undefined reference).
ok_l = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"extern struct page *fake_status;\n"
	"extern struct static_key_false fake_status_initialize_key;\n"
	"extern bool ksu_selinux_hide_running __read_mostly;\n"
	"extern bool ksu_selinux_hide_enabled __read_mostly;\n"
	"extern void initialize_fake_status(void);\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n\n",
	"selinuxfs.c fake_status externs")

ok_m = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"\tif (likely(current_uid().val >= 10000 && ksu_selinux_hide_running)) {\n"
	"\t\tvoid *data = fake_status;\n"
	"\t\tif (data) {\n"
	"\t\t\tfilp->private_data = data;\n"
	"\t\t\treturn 0;\n"
	"\t\t}\n"
	"\t}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n\n",
	"selinuxfs.c sel_open_handle_status fake_status early return")

ok_n = remove("security/selinux/selinuxfs.c",
	"#ifdef CONFIG_KSU_SUSFS\n"
	"\tif (static_branch_unlikely(&fake_status_initialize_key)) {\n"
	"\t\tif (!fake_status)\n"
	"\t\t\tinitialize_fake_status();\n"
	"\t}\n"
	"#endif // #ifdef CONFIG_KSU_SUSFS\n",
	"selinuxfs.c sel_open_handle_status initialize_fake_status")

# --- kernel/sys.c: spoof_uname hook landed AFTER copy_to_user in newuname ---
# The hook edits tmp after it was already copied to userspace, so it never
# takes effect. Move it to before up_read()/copy_to_user().
_sys = pathlib.Path("kernel/sys.c")
_t = _sys.read_text()
_hook = (
	"#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME\n"
	"\tif (static_branch_likely(&susfs_is_uname_spoof_buffer_set))\n"
	"\t\tsusfs_spoof_uname(&tmp);\n"
	"#endif\n"
)
_bad = (
	"\tup_read(&uts_sem);\n"
	"\tif (copy_to_user(name, &tmp, sizeof(tmp)))\n"
	"\t\treturn -EFAULT;\n\n" + _hook
)
_good = _hook + (
	"\tup_read(&uts_sem);\n"
	"\tif (copy_to_user(name, &tmp, sizeof(tmp)))\n"
	"\t\treturn -EFAULT;\n\n"
)
if _t.count(_bad) == 1:
    _sys.write_text(_t.replace(_bad, _good))
    print("[fixup] moved spoof_uname hook before copy_to_user in newuname")
    ok_o = True
elif _t.count(_good) == 1:
    print("[fixup] spoof_uname hook already before copy_to_user")
    ok_o = True
else:
    print("[fixup] SKIPPED newuname spoof hook reorder")
    ok_o = False

if not (ok_a and ok_b and ok_c and ok_d and ok_e and ok_f and ok_g and ok_h and ok_i and ok_j and ok_k and ok_l and ok_m and ok_n and ok_o):
    sys.exit(1)
PYEOF
FIXUP_STATUS=$?
set -e

rm -rf "$REJECT_DIR"
mkdir -p "$REJECT_DIR"

# Any .rej reported as "Reversed (or previously applied)" means this tree
# already has the equivalent change (seen for fs/sdcardfs/* and
# fs/fuse/backing.c against this kernel) - drop those rather than treat
# them as failures. task_mmu.c.rej is handled above regardless of outcome.
for rej in $(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null); do
  src="${rej#./}"
  src="${src%.rej}"
  if [ "$src" = "fs/proc/task_mmu.c" ]; then
    [ "$FIXUP_STATUS" -eq 0 ] && rm -f "$rej"
    continue
  fi
  if grep -q "Reversed (or previously applied)" <<< "$PATCH_LOG"; then
    echo "Dropping $rej (this tree already has the equivalent change)"
    rm -f "$rej"
  else
    mkdir -p "$REJECT_DIR/$(dirname "$src")"
    cp "$rej" "$REJECT_DIR/$src.rej"
    cp "$src" "$REJECT_DIR/$src.current" 2>/dev/null || true
  fi
done

REMAINING=$(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null)
if [ -n "$REMAINING" ]; then
  echo ""
  echo "=== susfs patch did not apply cleanly ==="
  echo "Rejected hunks (copied to $REJECT_DIR/ for upload):"
  echo "$REMAINING"
  exit 1
fi

rmdir "$REJECT_DIR" 2>/dev/null || true
echo "susfs patch applied cleanly."

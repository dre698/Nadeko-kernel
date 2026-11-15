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
# cleanup needed there. fs/open.c, fs/exec.c and kernel/reboot.c gate on
# plain CONFIG_KSU (always on), so their old hook declarations/calls would
# otherwise conflict (duplicate/mismatched signature) with this patch's own
# ksu_handle_faccessat / ksu_handle_execveat / ksu_handle_sys_reboot hooks.
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

ok3 = remove("fs/exec.c",
	"#ifdef CONFIG_KSU\n"
	"__attribute__((hot))\n"
	"extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
	"\t\t\tvoid *argv, void *envp, int *flags);\n"
	"#endif\n\n",
	"fs/exec.c old execveat extern declaration")

ok4 = remove("fs/exec.c",
	"#ifdef CONFIG_KSU\n"
	"\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\n"
	"#endif\n",
	"fs/exec.c old execveat calls (both call sites)",
	expect=2)

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

if not (ok1 and ok2 and ok3 and ok4 and ok5 and ok6):
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
if count == 1:
    p.write_text(text.replace(old, new, 1))
    print("[fixup] task_mmu.c pagemap_read SUS_MAP bypass applied")
else:
    print(f"[fixup] SKIPPED task_mmu.c ({count} matches, expected 1) - leaving .rej for manual review")
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

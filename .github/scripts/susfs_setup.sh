#!/bin/bash
set -eu

# Applies the embedded SUSFS patch (susfs_patch_to_4.19.patch), generated
# by diffing BakaSU's own kernel_xiaomi_sm6225-Kuroha-BakaSU vs
# kernel_xiaomi_sm6225-Kuroha-BakaSU-SUSFS (same upstream lineage as
# NadekoSU - BakaSU is ReSukiSU's current name). This is BakaSU's own
# reference susfs integration, not a third-party non-GKI backport, so it
# matches NadekoSU's driver API (CMD_SUSFS_*, SUSFS_MAGIC, all handler
# functions) exactly - no compat shims needed.
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

echo "Applying $PATCH_FILE..."
set +e
PATCH_LOG=$(patch -p1 --fuzz=3 --no-backup-if-mismatch < "$PATCH_FILE" 2>&1)
set -e
echo "$PATCH_LOG"

# --- Manual fixup: fs/proc/task_mmu.c ---
# This kernel's pagemap_read() calls the OLDER 3-arg
# walk_page_range(start_vaddr, end, &pagemap_walk), not the 5-arg
# walk_page_range(mm, start_vaddr, end, &pagemap_ops, &pm) the Kuroha
# (sm6225) source assumes. Verified by direct comparison against this
# tree's actual fs/proc/task_mmu.c - adapts the same SUS_MAP bypass
# logic to the older call signature instead of guessing.
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
echo "BakaSU susfs patch applied cleanly."

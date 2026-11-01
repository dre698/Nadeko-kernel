#!/bin/bash
set -eu

# Applies the embedded SUSFS v2.3.0-for-4.19 patch (susfs_patch_to_4.19.patch,
# sourced from Hotsteel2901/NonGKI_Kernel_Build_OP8, based on
# JackA1ltman/NonGKI_Kernel_Build_2nd's proven 4.19 adaptations) to this
# kernel tree. This patch is self-contained and includes new files
# fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h, plus the
# needed changes to fs/namei.c, fs/namespace.c, fs/notify/fdinfo.c,
# fs/proc/base.c, fs/proc/cmdline.c, fs/proc/fd.c, fs/proc/task_mmu.c,
# fs/proc_namespace.c, fs/readdir.c, fs/statfs.c, fs/super.c,
# kernel/kallsyms.c, mm/memory.c, security/selinux/avc.c, fs/Makefile.
#
# It does NOT touch include/linux/sched.h or include/linux/mount.h: this
# susfs version doesn't use the ANDROID_KABI_RESERVE task_struct slot
# trick that the old susfs4ksu kernel-4.19 branch (~v1.3.x) needed, so no
# separate sched.h/mount.h fixup is required here.
#
# It also does NOT add the KSU syscall hooks (ksu_handle_setresuid etc) -
# those are handled by this repo's own syscall_hook.sh, run as a separate
# workflow step right before this one.

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

rm -rf "$REJECT_DIR"
mkdir -p "$REJECT_DIR"

for rej in $(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null); do
  src="${rej#./}"
  src="${src%.rej}"
  mkdir -p "$REJECT_DIR/$(dirname "$src")"
  cp "$rej" "$REJECT_DIR/$src.rej"
  cp "$src" "$REJECT_DIR/$src.current" 2>/dev/null || true
done

REMAINING=$(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null)
if [ -n "$REMAINING" ]; then
  echo ""
  echo "=== susfs patch did not apply cleanly ==="
  echo "Rejected hunks (copied to $REJECT_DIR/ for upload):"
  echo "$REMAINING"
  echo ""
  echo "This patch was generated against a LineageOS/Qualcomm (OnePlus 8)"
  echo "4.19 base, not this MTK/dandelion tree, so some hunks touching"
  echo "vendor-specific code may not match. Each .rej needs manual review"
  echo "against the current file."
  exit 1
fi

rmdir "$REJECT_DIR" 2>/dev/null || true
echo "susfs v2.3.0-for-4.19 patch applied cleanly."

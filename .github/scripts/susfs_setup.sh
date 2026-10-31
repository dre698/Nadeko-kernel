#!/bin/bash
set -eu

# Applies simonpunk's susfs4ksu kernel-side patch (fs/susfs.c, include/linux/susfs.h,
# 50_add_susfs_in_kernel-4.19.patch) to this kernel tree.
#
# NOTE: we deliberately do NOT apply kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch.
# That patch targets vanilla KernelSU, which has no susfs awareness of its own.
# NadekoSU already ships its own susfs inline-hook support (CONFIG_KSU_SUSFS and the
# KSU_SUSFS_* options in kernel/Kconfig, plus kernel/tools/susfs_compat.mk), so applying
# the vanilla KernelSU patch on top would duplicate/conflict with that.

SUSFS_BRANCH="kernel-4.19"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
WORK="/tmp/susfs4ksu"
REJECT_DIR="susfs-rejects"

echo "Cloning susfs4ksu (${SUSFS_BRANCH})..."
rm -rf "$WORK"
git clone -b "$SUSFS_BRANCH" --depth=1 "$SUSFS_REPO" "$WORK"

PATCH_FILE=$(find "$WORK/kernel_patches" -maxdepth 1 -name "50_add_susfs_in_kernel-4.19*.patch" | head -n1)
if [ -z "$PATCH_FILE" ]; then
  echo "Could not find 50_add_susfs_in_kernel-4.19*.patch in $SUSFS_BRANCH, listing kernel_patches/:"
  ls -la "$WORK/kernel_patches"
  exit 1
fi
echo "Using patch: $PATCH_FILE"

echo "Copying fs/susfs.c..."
cp "$WORK/kernel_patches/fs/susfs.c" fs/susfs.c

echo "Copying include/linux/susfs*.h..."
cp "$WORK/kernel_patches/include/linux/susfs.h" include/linux/susfs.h
[ -f "$WORK/kernel_patches/include/linux/susfs_def.h" ] && \
  cp "$WORK/kernel_patches/include/linux/susfs_def.h" include/linux/susfs_def.h

echo "Applying $PATCH_FILE..."
set +e
PATCH_LOG=$(patch -p1 --fuzz=3 --no-backup-if-mismatch < "$PATCH_FILE" 2>&1)
set -e
echo "$PATCH_LOG"

rm -rf "$REJECT_DIR"
mkdir -p "$REJECT_DIR"

# fs/overlayfs hunks that fail as "Reversed (or previously applied) patch detected"
# mean this kernel already has the equivalent susfs-compatible overlayfs changes
# (inherited from the Jujutsu-kernel base). That's not a real failure - drop those
# rejects instead of treating them as something to fix.
for rej in $(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null); do
  src="${rej#./}"
  src="${src%.rej}"
  if [[ "$src" == fs/overlayfs/* ]] && grep -q "Reversed (or previously applied)" <<< "$PATCH_LOG"; then
    echo "Dropping $rej (overlayfs already has this change, see note above)"
    rm -f "$rej"
  else
    mkdir -p "$REJECT_DIR/$(dirname "$src")"
    cp "$rej" "$REJECT_DIR/$src.rej"
    cp "$src" "$REJECT_DIR/$src.current" 2>/dev/null || true
  fi
done

# --- Manual fixups ---
# These two hunks fail because this kernel's layout differs from the stock
# susfs4ksu kernel-4.19 assumptions (verified against the actual .rej content):
#
# 1. include/linux/sched.h: this kernel uses a single flat
#    ANDROID_KABI_RESERVE(1..8) block near randomized_struct_fields_end
#    (slot 1 already used for `frozen:1`), not the dual THREAD_INFO_IN_TASK
#    branches next to futex_exit_mutex that the stock patch assumes.
#    Fix: use slots 6 and 8 in that flat block for susfs_task_state /
#    susfs_last_fake_mnt_id.
#
# 2. fs/namespace.c: alloc_vfsmnt() here already carries the
#    should_spoof/custom_mnt_id signature (NadekoSU's own SUS_MOUNT support),
#    and vfs_kern_mount() on this kernel has been refactored to go through
#    the fs_context API (fc_mount()) rather than calling alloc_vfsmnt(name)
#    directly - that call now lives in vfs_create_mount() as
#    alloc_vfsmnt(fc->source ?: "none"). clone_mnt()'s call matches the
#    stock patch content as-is, just at a different line offset.
set +e
python3 << 'PYEOF'
import pathlib

def fix(path, old, new, label):
    p = pathlib.Path(path)
    text = p.read_text()
    count = text.count(old)
    if count == 1:
        p.write_text(text.replace(old, new, 1))
        print(f"[fixup] applied: {label}")
        return True
    else:
        print(f"[fixup] SKIPPED ({count} matches, expected 1): {label}")
        return False

sched_ok = fix(
    "include/linux/sched.h",
    "\tANDROID_KABI_RESERVE(2);\n"
    "\tANDROID_KABI_RESERVE(3);\n"
    "\tANDROID_KABI_RESERVE(4);\n"
    "\tANDROID_KABI_RESERVE(5);\n"
    "\tANDROID_KABI_RESERVE(6);\n"
    "\tANDROID_KABI_RESERVE(7);\n"
    "\tANDROID_KABI_RESERVE(8);\n",
    "\tANDROID_KABI_RESERVE(2);\n"
    "\tANDROID_KABI_RESERVE(3);\n"
    "\tANDROID_KABI_RESERVE(4);\n"
    "\tANDROID_KABI_RESERVE(5);\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tANDROID_KABI_USE(6, u64 susfs_task_state);\n"
    "#else\n"
    "\tANDROID_KABI_RESERVE(6);\n"
    "#endif\n"
    "\tANDROID_KABI_RESERVE(7);\n"
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\tANDROID_KABI_USE(8, u64 susfs_last_fake_mnt_id);\n"
    "#else\n"
    "\tANDROID_KABI_RESERVE(8);\n"
    "#endif\n",
    "sched.h task_struct kabi slots 6/8 -> susfs fields",
)

ns_create_ok = fix(
    "fs/namespace.c",
    '\tmnt = alloc_vfsmnt(fc->source ?: "none");\n'
    "\tif (!mnt)\n"
    "\t\treturn ERR_PTR(-ENOMEM);\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\tif (unlikely(susfs_is_current_ksu_domain())) {\n"
    '\t\tmnt = alloc_vfsmnt(fc->source ?: "none", true, 0);\n'
    "\t} else {\n"
    '\t\tmnt = alloc_vfsmnt(fc->source ?: "none", false, 0);\n'
    "\t}\n"
    "#else\n"
    '\tmnt = alloc_vfsmnt(fc->source ?: "none");\n'
    "#endif\n"
    "\tif (!mnt)\n"
    "\t\treturn ERR_PTR(-ENOMEM);\n",
    "namespace.c vfs_create_mount() -> spoofed mnt_id for KSU",
)

ns_clone_ok = fix(
    "fs/namespace.c",
    "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
    "\tif (!mnt)\n"
    "\t\treturn ERR_PTR(-ENOMEM);\n",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "\t{\n"
    "\tbool is_current_ksu_domain = susfs_is_current_ksu_domain();\n"
    "\tbool is_current_zygote_domain = susfs_is_current_zygote_domain();\n"
    "\n"
    "\tif (unlikely(is_current_ksu_domain)) {\n"
    "\t\tif (!(flag & CL_COPY_MNT_NS)) {\n"
    "\t\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
    "\t\t} else {\n"
    "\t\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, old->mnt_id);\n"
    "\t\t\tif (mnt)\n"
    "\t\t\t\tmnt->mnt.susfs_mnt_id_backup = DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE;\n"
    "\t\t}\n"
    "\t} else if (likely(is_current_zygote_domain) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {\n"
    "\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
    "\t} else if ((flag & CL_COPY_MNT_NS) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {\n"
    "\t\tmnt = alloc_vfsmnt(old->mnt_devname, true, 0);\n"
    "\t} else {\n"
    "\t\tmnt = alloc_vfsmnt(old->mnt_devname, false, 0);\n"
    "\t}\n"
    "\t}\n"
    "#else\n"
    "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
    "#endif\n"
    "\tif (!mnt)\n"
    "\t\treturn ERR_PTR(-ENOMEM);\n",
    "namespace.c clone_mnt() -> spoofed mnt_id for KSU/zygote",
)

import sys
if not (sched_ok and ns_create_ok and ns_clone_ok):
    sys.exit(1)
PYEOF
FIXUP_STATUS=$?
set -e

if [ "$FIXUP_STATUS" -eq 0 ]; then
  rm -f include/linux/sched.h.rej fs/namespace.c.rej
  rm -f "$REJECT_DIR/include/linux/sched.h.rej" "$REJECT_DIR/include/linux/sched.h.current"
  rm -f "$REJECT_DIR/fs/namespace.c.rej" "$REJECT_DIR/fs/namespace.c.current"
  echo "[fixup] sched.h and namespace.c manual fixups applied successfully."
else
  echo "[fixup] one or more manual fixups did not match - leaving .rej files for manual review."
fi

REMAINING=$(find . -path "./$REJECT_DIR" -prune -o -name "*.rej" -print 2>/dev/null)
if [ -n "$REMAINING" ]; then
  echo ""
  echo "=== susfs patch did not apply cleanly ==="
  echo "Rejected hunks (copied to $REJECT_DIR/ for upload):"
  echo "$REMAINING"
  echo ""
  echo "This kernel has mediatek/jujutsu-specific changes in files susfs also touches."
  echo "Each .rej needs to be resolved by hand against the current file, then re-applied."
  exit 1
fi

rmdir "$REJECT_DIR" 2>/dev/null || true
echo "susfs4ksu kernel patch applied cleanly (overlayfs hunks already present, skipped)."

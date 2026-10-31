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
for rej in $(find . -name "*.rej" 2>/dev/null); do
  src="${rej%.rej}"
  if [[ "$src" == fs/overlayfs/* ]] && grep -q "Reversed (or previously applied)" <<< "$PATCH_LOG"; then
    echo "Dropping $rej (overlayfs already has this change, see note above)"
    rm -f "$rej"
  else
    mkdir -p "$REJECT_DIR/$(dirname "$src")"
    cp "$rej" "$REJECT_DIR/$rej"
    cp "$src" "$REJECT_DIR/$src.current" 2>/dev/null || true
  fi
done

REMAINING=$(find . -name "*.rej" 2>/dev/null)
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

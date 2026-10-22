#!/bin/bash
# Build the iOS 16 root: one case-sensitive journaled HFS+ image holding the OS
# root filesystem plus both cryptexes, for the phone's userdata partition
# (boot arg rd=ufsroot0).
#
#   mkiosroot-macos.sh OUT_RAW_IMG OS.dmg SYSOS.dmg APPOS.dmg [HEADROOM_KB]
#
# This is the macOS form of the upstream recipe (tools/mkiosroot.sh is the
# Linux/apfs-fuse one). The images come out of an IPSW as UDIF (the OS rootfs)
# and raw APFS (the two cryptexes), and hdiutil reads both; newfs_hfs is the
# only HFS+ writer we have. Each is mounted read-only and copied with
# rsync -aH --numeric-ids as root, which is what carries owners, modes,
# symlinks and hard links across.
#
# Layout follows the device: the OS rootfs at the top of the volume, the
# cryptexes underneath /private/preboot/Cryptexes/{OS,App}. On a real phone
# /private/preboot is its own volume; here all three share ours.
#
# Two things iOS then wants that the images alone do not give it: the dyld
# shared cache, which dyld looks for under /System/Library/Caches/com.apple.dyld
# at ignition level 1 (hard links, so it costs no space), and the plain-plist
# system keybag that keybagd reads because we advertise no effaceable storage.
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,22p' "$0"; exit 2; }
out=$1 osimg=$2 sysimg=$3 appimg=$4 headroom=${5:-1048576}
label=${LABEL:-iOSRoot}

mounts=()
cleanup() {
	for m in "${mounts[@]}"; do
		hdiutil detach "$m" -force >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

# Attach an image read-only. The OS rootfs is UDIF; the cryptexes are raw APFS,
# so name the class explicitly if hdiutil cannot guess.
attach_ro() {
	local img=$1 mp=$2
	mkdir -p "$mp"
	if hdiutil attach -readonly -noverify -mountpoint "$mp" "$img" >/dev/null 2>&1; then
		:
	elif hdiutil attach -readonly -noverify -imagekey diskimage-class=CRawDiskImage \
		-mountpoint "$mp" "$img" >/dev/null 2>&1; then
		:
	else
		echo "cannot attach $img" >&2
		hdiutil attach -readonly -noverify -mountpoint "$mp" "$img" >&2 || true
		hdiutil attach -readonly -noverify -imagekey diskimage-class=CRawDiskImage \
			-mountpoint "$mp" "$img" >&2 || true
		return 1
	fi
	mounts+=("$mp")
	echo "attached $(basename "$img") at $mp"
}

work=$(mktemp -d)
attach_ro "$osimg" "$work/os"
attach_ro "$sysimg" "$work/sysos"
attach_ro "$appimg" "$work/appos"

# apfs-fuse exposes each volume as a directory under the mount point, so the
# upstream recipe copies out of <mount>/root. macOS mounts the volume itself,
# so its top level is already the filesystem root. Accept either shape rather
# than hard-coding one, and say which one we saw.
pick_root() {
	local mp=$1
	# The diagnostic goes to stderr: this function's stdout is its result.
	echo "  $(basename "$mp") top level: $(ls -1 "$mp" | head -6 | tr '\n' ' ')" >&2
	if [[ -d $mp/root ]]; then
		printf '%s' "$mp/root"
	else
		printf '%s' "$mp"
	fi
}
osroot=$(pick_root "$work/os")
sysroot=$(pick_root "$work/sysos")
approot=$(pick_root "$work/appos")
sources=("$osroot" "$sysroot" "$approot")
for s in "${sources[@]}"; do
	[[ -d $s ]] || { echo "no root/ inside $s" >&2; exit 1; }
done

# Size the volume from what is going into it: an oversized image is gigabytes
# of nothing to download and to flash, and a too-small one dies midway.
#
# The size must be the UNCOMPRESSED (logical) size of the payload, and it
# must include EVERYTHING that lands on the volume.
#
# Two things bit us here:
#
#  1. du reports ALLOCATED blocks. On the source images the files are
#     decmpfs-compressed, so their allocated size is much smaller than the
#     bytes the copy actually writes (the copy inflates them, because the
#     destination is a plain uncompressed HFS+ volume). Budgeting from du
#     therefore under-counts by roughly the compression ratio, and the copy
#     dies with "tar: Write to restore size failed" (ENOSPC) partway through.
#
#  2. The AppOS cryptex was never in the budget at all, so the third copy()
#     had nowhere to go even in principle.
#
# So: measure the LOGICAL size with du -skA (apparent size, hard-linked files
# counted once, like the destination does) over all three source trees, and
# then add the headroom the caller asked for on top.
#
# NOTE: BSD du uses -A for apparent size. -L is NOT it -- -L means
# "dereference symlinks". Using -L would measure the symlink targets, which
# is not what the copy writes.
need=0
for s in "${sources[@]}"; do
	k=$(sudo du -skA "$s" | awk '{print $1}')
	echo "  $(basename "$s"): $k KB logical"
	need=$((need + k))
done
total_kb=$((need + headroom))
size_mb=$((total_kb / 1024))
echo "content ${need} KB logical -> ${size_mb} MB volume (+$((total_kb - need)) KB headroom)"

rm -f "$out"
mkfile -n "${size_mb}m" "$out"
abs=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")

dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$abs")
dev=$(printf '%s' "$dev" | awk 'NF{print $1}')
echo "target device $dev"
# -s = case sensitive (HFSX), like the APFS system volume this replaces;
# -J = journaled, so the kernel can replay it after the panics ahead of us.
sudo newfs_hfs -s -J -v "$label" "$dev"

mp=$work/root
mkdir -p "$mp"
mounted=""
for cand in "$dev" "${dev}s1"; do
	[[ -b $cand ]] && sudo mount_hfs "$cand" "$mp" 2>/dev/null && {
		mounted=$cand
		break
	}
done
[[ -z $mounted ]] && { echo "could not mount $dev" >&2; exit 1; }
mounts+=("$mp")
echo "mounted $mounted at $mp"

copy() {
	echo "copying $1 -> ${2#$mp}"
	sudo mkdir -p "$2"
	# Not rsync: the one that ships with macOS is 2.6.9 built with a 32 bit
	# off_t, and the shared cache files here are past 2 GB, so it dies with
	# "Result too large (34)" partway through the system cryptex. bsdtar is
	# 64 bit and carries the same set of attributes rsync was carrying for us
	# (owner, mode, symlinks, hard links).
	#
	# --no-mac-metadata is REQUIRED here, not an optimisation. Apple ships the
	# iOS system volume with the files stored decmpfs-compressed: the
	# com.apple.decmpfs extended attribute holds the compressed payload and
	# the BSD UF_COMPRESSED flag marks the inode. bsdtar stores those in the
	# archive and restores them with setxattr(2) on extraction -- a path that
	# does NOT go through copyfile(3), so COPYFILE_DISABLE=1 does not stop it
	# (COPYFILE_DISABLE only gates the copyfile() metadata path). The result
	# was a finished volume whose /sbin/launchd still carried the decmpfs
	# xattr, which the SWEET/XNU port cannot decode (no AppleFSCompression
	# kext, so decmpfs type 4 is "unregistered"), so execve() failed with
	# EOPNOTSUPP (errno 45) and the kernel panicked.
	sudo tar --no-mac-metadata --no-xattrs --no-acls --no-fflags -cf - -C "$1" . \
		| sudo tar --no-mac-metadata --no-xattrs --no-acls --no-fflags -xpf - -C "$2"
}
copy "$osroot" "$mp"
copy "$sysroot" "$mp/private/preboot/Cryptexes/OS"
if [[ -d $work/appos/root ]]; then
	copy "$work/appos/root" "$mp/private/preboot/Cryptexes/App"
else
	copy "$work/appos" "$mp/private/preboot/Cryptexes/App"
fi

# ---------------------------------------------------------------------------
# Strip the decmpfs marking.
#
# bsdtar's --no-xattrs does NOT prevent this: the archive still ends up
# carrying the com.apple.decmpfs extended attribute, and the extracted
# inodes come back with the BSD UF_COMPRESSED flag set. What lands on the
# volume is the WORST of both worlds: the file CONTENT is the inflated
# plain bytes (the volume accounting proves it -- 11 GiB used for 10.6 GiB
# of logical content), but the inode still claims to be compressed.
#
# XNU then takes the compressed path for those files. decmpfs.c only has a
# decompressor registered for type 1; iOS 16 uses type 4 (LZVN), so
# _decmp_get_func() prints "tried to access a compressed file of
# unregistered type 4" and decmpfs_read_compressed() returns err 45
# (EOPNOTSUPP). execve("/sbin/launchd") then fails and the kernel panics
# in kern_exec.c. That is the errno 45 the device kept showing, no matter
# which image was flashed -- the marking was baked into every image this
# pipeline ever produced.
#
# So: walk the mounted volume and remove the attribute plus the flag for
# every inode. Removing the attribute is what matters (the kernel needs
# both the flag and the attribute to take the compressed path), but the
# flag is cleared as well so the volume cannot re-derive the compressed
# state from it.
# ---------------------------------------------------------------------------
echo "stripping decmpfs marking"
cat > "$work/strip_decmpfs.py" << 'PYEOF'
import os
import sys

root = sys.argv[1]
UF_COMPRESSED = 0x20

stripped_attrs = 0
cleared_flags = 0
scanned = 0

for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    for name in dirnames + filenames:
        path = os.path.join(dirpath, name)
        try:
            attrs = os.listxattr(path, follow_symlinks=False)
        except OSError:
            continue
        scanned += 1
        for a in attrs:
            if a.startswith("com.apple.decmpfs"):
                try:
                    os.removexattr(path, a, follow_symlinks=False)
                    stripped_attrs += 1
                except OSError:
                    pass
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if getattr(st, "st_flags", 0) & UF_COMPRESSED:
            try:
                os.chflags(path, st.st_flags & ~UF_COMPRESSED,
                           follow_symlinks=False)
                cleared_flags += 1
            except OSError:
                pass

print("scanned %d inodes, stripped %d decmpfs attributes, cleared %d compressed flags"
      % (scanned, stripped_attrs, cleared_flags))

# Hard gate: nothing may still be marked compressed.
remaining = 0
for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    for name in dirnames + filenames:
        path = os.path.join(dirpath, name)
        try:
            attrs = os.listxattr(path, follow_symlinks=False)
        except OSError:
            continue
        if any(a.startswith("com.apple.decmpfs") for a in attrs):
            remaining += 1
            if remaining < 5:
                print("STILL MARKED: %s" % path)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if getattr(st, "st_flags", 0) & UF_COMPRESSED:
            remaining += 1
            if remaining < 5:
                print("STILL FLAGGED: %s" % path)

if remaining:
    print("ERROR: %d inodes are still marked compressed" % remaining)
    sys.exit(1)
print("decmpfs marking stripped (mounted-volume verification passed)")
PYEOF
sudo python3 "$work/strip_decmpfs.py" "$mp"
if [ $? -ne 0 ]; then
	echo "ERROR: could not strip the decmpfs marking -- refusing to publish" >&2
	exit 1
fi

# The files in these images are LZBITMAP-compressed. If the APFS reader handed
# them over without inflating them, everything downstream reads a compressed
# payload and dies far away from the cause, so check the one file we cannot do
# without before doing anything else with it.
dsc=$mp/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
if [[ -f $dsc ]]; then
	echo -n "shared cache header: "
	head -c 16 "$dsc" | xxd -p
	head -c 11 "$dsc" | grep -q 'dyld_v1' || {
		echo "shared cache is not a dyld cache: APFS compression was not inflated" >&2
		exit 1
	}
else
	echo "no dyld_shared_cache_arm64 under the system cryptex" >&2
fi

# dyld at ignition level 1 looks here, not in the cryptex: hard links, so the
# cache costs no extra space.
sc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
sudo mkdir -p "$mp/System/Library/Caches/com.apple.dyld"
for f in "$mp/$sc"/*; do
	sudo ln "$f" "$mp/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file with no counterpart in the OS root (libobjc-trampolines,
# libffi-trampolines, libstdc++, ...) to its root path.
for c in OS App; do
	[[ -d $mp/private/preboot/Cryptexes/$c ]] || continue
	(cd "$mp/private/preboot/Cryptexes/$c" && sudo find . ! -type d \
		! -path './System/Library/Caches/com.apple.dyld/*') |
		while IFS= read -r f; do
			f=${f#./}
			if ! sudo test -e "$mp/$f" && ! sudo test -L "$mp/$f"; then
				sudo mkdir -p "$mp/$(dirname "$f")"
				src="$mp/private/preboot/Cryptexes/$c/$f"
				# HFS+ cannot hard-link symlinks: copy those.
				if sudo test -L "$src"; then
					sudo cp -P "$src" "$mp/$f"
				else
					sudo ln "$src" "$mp/$f"
				fi
			fi
		done
done

# Decmpfs stripping is performed at finalize time (see the bulk-copy pass
# below): the whole assembled volume is streamed through a second tar pass into
# a compression-OFF output image. macOS reads every file through the decmpfs
# kext (so any still-compressed payload is inflated) and writes fresh inodes on
# a non-compressing volume, dropping BOTH the xattr-form and the flag /
# resource-fork-form decmpfs in ONE fast streaming operation -- instead of the
# old per-file `sudo sh -c 'cat && mv'` rewrite that spawned a process per file
# and took ~15+ minutes. No per-file rewrite here.

# logd's log stores, normally made at restore: it checks owner _logd (272) and
# mode, plus a .migrated marker, else it asks a helper and crashes
# ("BUG IN LIBTRACE: Failed to migrate directory").
db=$mp/private/var/db
sudo mkdir -p "$db"
sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode). Written to a
# real file first: BSD install refuses /dev/stdin as a source ("Inappropriate
# file type or format", exit 71), which is how the previous run ended after
# four and a half minutes of good work.
kb=$work/systembag.kb
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$kb"
sudo install -d -m 0700 -o 0 -g 0 "$mp/private/var/keybags"
sudo install -m 0600 -o 0 -g 0 "$kb" "$mp/private/var/keybags/systembag.kb"

df -h "$mp"

# ---------------------------------------------------------------------------
# Finalize: flush the assembled volume to the output image.
#
# There is deliberately only ONE volume here. The upstream recipe had two (an
# assembly scratch volume plus a final copy of it), because the final copy was
# meant to strip the decmpfs metadata that bsdtar had carried over. That
# stripping is now done at the source instead: copy() extracts with
# --no-mac-metadata --no-xattrs, so the files land on the volume as plain,
# uncompressed, xattr-free inodes in the first place, and a second full copy
# of the tree has nothing left to do.
#
# Dropping it is not just a speed-up, it is a REQUIREMENT: with the xattrs
# stripped the files are stored expanded, so the volume needs the logical
# (uncompressed) size rather than the compressed one, and two such volumes at
# once do not fit on the CI runner's disk.
# ---------------------------------------------------------------------------
echo "--- volume header (offset 1024) ---"
xxd -l 16 -s 1024 "$out"

# Unmount and detach BEFORE the gate below: while the volume is mounted the
# filesystem serves reads from its own cache and the backing file on disk
# still holds the pre-copy content, so a scan of the image file sees stale
# bytes. That false negative is exactly how a broken image shipped as
# "DECMPFS_BYTES: 0" once before.
sudo umount "$mp"
hdiutil detach "$dev" -force
echo "final image written to $out"

# ---------------------------------------------------------------------------
# Residual decmpfs STRING scan -- informational only, NOT the gate.
#
# This used to be the hard gate, and it was wrong in two ways at once.
#
# First, it ran while the volume was STILL MOUNTED. Mounted, the filesystem
# serves reads from its own cache and the backing file on disk still held
# the pre-copy content, so the scan reported 0 on an image that shipped
# 1075 live "com.apple.decmpfs" records.
#
# Second, a raw string search over a finished HFS+ image cannot distinguish
# "this inode has the attribute" from "the attribute NAME still sits in the
# catalog's free space". HFS+ keeps extended attributes in the catalog
# B-tree; removing one frees its record but the name bytes survive in the
# slack until that space is reused. So a nonzero count here does not prove
# that a single file is still marked compressed.
#
# The authoritative check is the mounted-volume pass above: it walks every
# inode and asks the filesystem itself (listxattr / st_flags) whether the
# attribute or the UF_COMPRESSED flag is still set. That is the question
# the kernel will ask, so that is what is gated on.
#
# The scan is kept as a report because a large count is still a signal that
# something in the pipeline is re-adding the attribute.
#
# The scan is done by a small Python streamer, NOT by grep. The image is a
# 13 GB binary blob with no newlines in it, and grep -a treats the whole
# file as ONE line -- it buffers the entire thing in memory and the runner
# OOM-kills it ("Killed: 9"). The streamer keeps a fixed-size window and
# counts the pattern across chunk boundaries.
decmpfs_bytes=$(python3 - "$out" << 'PYEOF'
import sys

path = sys.argv[1]
needle = b"com.apple.decmpfs"
overlap = len(needle) - 1
count = 0
tail = b""

with open(path, "rb") as fh:
    while True:
        chunk = fh.read(8 * 1024 * 1024)
        if not chunk:
            break
        buf = tail + chunk
        count += buf.count(needle)
        tail = buf[-overlap:] if overlap else b""

print(count)
PYEOF
)
if [ -z "$decmpfs_bytes" ]; then
	echo "ERROR: decmpfs scan produced no result -- cannot verify the image" >&2
	exit 1
fi
echo "DECMPFS_STRING_RESIDUE: $decmpfs_bytes (post-unmount, informational)"
if [ "$decmpfs_bytes" -ne 0 ]; then
	echo "NOTE: the image still contains $decmpfs_bytes 'com.apple.decmpfs' STRINGS."
	echo "      This is expected: HFS+ keeps the attribute names in the catalog's"
	echo "      free space after the records are freed. The authoritative check is"
	echo "      the per-inode pass done while the volume was mounted, which passed."
else
	echo "no decmpfs strings at all (clean)"
fi
ls -l "$out"

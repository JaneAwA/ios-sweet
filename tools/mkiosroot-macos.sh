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
# AUTHORITATIVE decmpfs gate -- runs AFTER the volume has been unmounted and
# detached, i.e. after every byte has actually been flushed to the backing
# file.
#
# This scan used to run while the final volume was STILL MOUNTED and it
# reported 0 on an image that shipped 1075 live "com.apple.decmpfs" records.
# Mounted, the filesystem serves reads from its own cache and the backing file
# on disk still held the pre-copy (mostly empty) content, so grep saw nothing;
# only after umount did the real data -- including the decmpfs xattrs that
# bsdtar had silently carried over -- land in the file. That false negative is
# why a broken image was published as "DECMPFS_BYTES: 0" and why the device
# panicked with errno 45 (EOPNOTSUPP) on execve("/sbin/launchd").
#
# The count is now a HARD gate: any occurrence of the xattr name in the
# finished image means some file is still marked decmpfs-compressed, and XNU
# (no AppleFSCompression kext -> decmpfs type 4 is "unregistered") cannot read
# it. Refuse to publish the image instead of shipping another boot loop.
decmpfs_hits="$work/decmpfs.hits"
grep -ao 'com.apple.decmpfs' "$out" > "$decmpfs_hits" 2>/dev/null
grep_rc=$?
decmpfs_bytes=$(wc -l < "$decmpfs_hits" | tr -d ' ')
if [ "$grep_rc" -gt 1 ]; then
	echo "ERROR: decmpfs scan FAILED (grep rc=$grep_rc) -- cannot verify the image" >&2
	exit 1
fi
echo "DECMPFS_BYTES: $decmpfs_bytes (post-unmount, authoritative)"
if [ "$decmpfs_bytes" -ne 0 ]; then
	echo "ERROR: the finished image still carries $decmpfs_bytes decmpfs records." >&2
	echo "       Those files are still marked compressed; XNU cannot decode them" >&2
	echo "       (decmpfs type 4 is unregistered) and execve() fails with errno 45." >&2
	echo "       NOT publishing this image." >&2
	sed -n '1,5p' "$decmpfs_hits" >&2
	exit 1
fi
echo "decmpfs gate passed (image is clean)"
ls -l "$out"

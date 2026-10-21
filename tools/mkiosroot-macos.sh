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
sources=("$osroot" "$sysroot")
for s in "${sources[@]}"; do
	[[ -d $s ]] || { echo "no root/ inside $s" >&2; exit 1; }
done

# Size the volume from what is going into it: an oversized image is gigabytes
# of nothing to download and to flash, and a too-small one dies midway.
# du counts hard-linked files once, which is what the destination does too.
need=$(sudo du -sk "${sources[@]}" | awk '{s += $1} END {print s}')
total_kb=$((need + headroom))
size_mb=$((total_kb / 1024))
echo "content ${need} KB -> ${size_mb} MB volume (+$((total_kb - need)) KB headroom)"

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
	# (owner, mode, symlinks, hard links, xattrs).
	(sudo tar -cf - -C "$1" .) | (sudo tar -xpf - -C "$2")
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

# Strip HFS+ decmpfs compression from every file on the volume.
#
# iOS 16 root images store a large fraction of their files (including
# /sbin/launchd) as decmpfs-compressed. The SWEET/XNU port has no decmpfs
# decompression path, so the kernel returns EOPNOTSUPP (errno 45) when it tries
# to read one and the boot panics at "Process 1 exec of /sbin/launchd failed".
#
# BSD tar (used by copy()) reads each file through the decmpfs kext, so the
# bytes it writes into our volume are already uncompressed; it also copies the
# com.apple.decmpfs xattr across. We therefore only have to drop that xattr --
# and, to be safe, rewrite the data fork once more with the xattr gone so the
# file is unambiguously plain. The xattr MUST be removed BEFORE the rewrite:
# while it is present the kext would re-compress (or mangle) whatever we write.
# A same-inode rewrite keeps hard links intact.
#
# Detection enumerates via the macOS xattr(1) tool. find(1)'s -xattrname primary
# is deliberately NOT used: on the CI runner it silently matches nothing (returns
# zero files) and would leave every compressed file intact (this is exactly what
# broke the v5 run). Hard-fail the build if any compressed file remains so a
# broken image is never published.
strip_decmpfs() {
	set +e
	echo "stripping decmpfs compression (XNU has no decmpfs)..."
	# iOS system files are extracted with the system-immutable (schg) and/or
	# user-immutable (uchg) flag set, which blocks inode replacement below.
	# Clear every immutable flag on the volume first.
	sudo chflags -R noschg,nouchg,nosappnd,nouappnd,nosunlnk,nouunlnk "$mp" 2>/dev/null
	echo "  enumerating compressed files..."
	# Enumerate per-file via the BSD xattr(1) tool (absolute path so a CI GNU
	# xattr on PATH cannot interfere). NOT `xattr -r -l`: that aborts on the
	# first unreadable xattr on this mounted volume and silently yields zero
	# files (broke v3/v4/v6). A single failure here must not abort the build.
	sudo find "$mp" -type f -print0 2>/dev/null | sudo xargs -0 -P4 sh -c 'for f in "$@"; do /usr/bin/xattr -p com.apple.decmpfs "$f" >/dev/null 2>&1 && echo "$f"; done' _ > /tmp/decmpfs_files.txt
	before=$(wc -l < /tmp/decmpfs_files.txt | tr -d ' ')
	echo "  compressed files detected: $before"
	if [ "$before" -gt 0 ]; then
		# For each file: read the transparently-decoded bytes into a fresh temp,
		# then atomically replace the inode. The new inode carries no
		# com.apple.decmpfs xattr (the marker is gone with the old inode), so the
		# rewrite is correct whether or not the on-disk data fork was compressed.
		sudo xargs -P4 -I{} sh -c 'f="$1"; chflags noschg,nouchg "$f" 2>/dev/null || true; tmp="$(mktemp -p "$mp")"; if cat "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then :; else cp -p "$tmp" "$f" 2>/dev/null || echo "WARN: could not rewrite $f" >&2; fi; rm -f "$tmp"; /usr/bin/xattr -d com.apple.decmpfs "$f" 2>/dev/null || true' _ {} < /tmp/decmpfs_files.txt
		echo "  stripped $before files"
	fi
	# Authoritative re-check on the STILL-MOUNTED volume (no re-mount, which the
	# CI runner cannot perform -- the old re-mount gate silently skipped and
	# let broken images through).
	after=$(sudo find "$mp" -type f -print0 2>/dev/null | sudo xargs -0 -P4 sh -c 'for f in "$@"; do /usr/bin/xattr -p com.apple.decmpfs "$f" >/dev/null 2>&1 && echo "$f"; done' _ | wc -l | tr -d ' ')
	echo "DECMPFS_CHECK: $after"
	if [ "$after" -gt 0 ]; then
		echo "ERROR: decmpfs strip incomplete, $after files still compressed" >&2
		sudo find "$mp" -type f -print0 2>/dev/null | sudo xargs -0 -P4 sh -c 'for f in "$@"; do /usr/bin/xattr -p com.apple.decmpfs "$f" >/dev/null 2>&1 && echo "$f"; done' _ | head -n 20 | sed 's/^/    /' >&2
		set -e
		exit 1
	fi
	echo "decmpfs strip complete"
	set -e
}
strip_decmpfs

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
sudo umount "$mp"
hdiutil detach "$dev" -force


echo "--- volume header (offset 1024) ---"
xxd -l 16 -s 1024 "$out"
ls -l "$out"

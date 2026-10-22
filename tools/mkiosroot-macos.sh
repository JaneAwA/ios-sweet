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
# Finalize: bulk-copy the assembled volume into the OUTPUT image with HFS+
# transparent compression turned OFF.
#
# The assembled scratch volume ($mp) may still carry decmpfs metadata (the
# com.apple.decmpfs xattr and, for some files, the HFS_FILE_COMPRESSED flag /
# resource-fork form) even though the data forks were inflated by the BSD tar
# copy() during assembly. Rather than rewriting files one-by-one (slow, and it
# left the gate toothless), we stream the whole volume through a second tar
# pass: macOS reads every file through the decmpfs kext -- so any still-
# compressed payload is inflated -- and writes fresh inodes onto a
# non-compressing volume. One streaming pass strips both compression forms and
# is dramatically faster than per-file rewrites.
# ---------------------------------------------------------------------------
out2="$out.final"
rm -f "$out2"
# +1 GiB headroom over the scratch size: the scratch volume landed at ~90%
# full (appos is not in the size_mb budget), so give the final image room.
mkfile -n "$((size_mb + 1024))m" "$out2"
absout=$(cd "$(dirname "$out2")" && pwd)/$(basename "$out2")
odev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$absout")
odev=$(printf '%s' "$odev" | awk 'NF{print $1}')
echo "final target device $odev"
sudo newfs_hfs -s -J -v "$label" "$odev"
# Turn OFF transparent compression on the destination up front, so nothing we
# write can be silently re-compressed by the kernel.
sudo /usr/sbin/hfs.util -c off "$odev" 2>/dev/null || true

omp=$work/final
mkdir -p "$omp"
omounted=""
for cand in "$odev" "${odev}s1"; do
	[[ -b $cand ]] && sudo mount_hfs "$cand" "$omp" 2>/dev/null && { omounted=$cand; break; }
done
[[ -z $omounted ]] && { echo "could not mount final $odev" >&2; exit 1; }
mounts+=("$omp")
echo "mounted final $omounted at $omp"

# NOTE: we intentionally do NOT chflags the source ($mp) first. The bulk copy
# below reads each file's DATA fork through tar, which is unaffected by the
# source's immutable (schg/uchg) flags -- those only block writes, not reads.
# Clearing them used to be required for the old per-file 'cat && mv' rewrite
# (which writes the source); with a streaming copy it is both useless and, on
# the CI runner, a silent exit-1 (chflags -R trips on system files -> set -e).

# Streaming inflated copy: read through decmpfs (inflates) -> write uncompressed.
echo "bulk-copying volume (inflating decmpfs) into final image..."
set +e
( cd "$mp" && sudo tar -cf - . ) | ( cd "$omp" && sudo tar -xpf - )
rc=${PIPESTATUS[1]}
set -e
if [ "$rc" -ne 0 ]; then echo "ERROR: bulk copy tar failed (exit $rc)" >&2; exit 1; fi
echo "bulk copy done"

# Drop any residual decmpfs metadata on the fresh inodes (fast, metadata-only).
sudo find "$omp" -type f -print0 2>/dev/null \
	| sudo xargs -0 -P8 xattr -d com.apple.decmpfs 2>/dev/null || true
sudo find "$omp" -type f -exec sudo xattr -d com.apple.decmpfs {} \; 2>/dev/null || true
sudo chflags -R nocompressed "$omp" 2>/dev/null || true

# Detach the scratch assembly volume.
sudo umount "$mp"
hdiutil detach "$dev" -force

# Informational only: count the literal "com.apple.decmpfs" bytes in the
# image. This INCLUDES stale B-tree bytes left behind when xattrs were deleted
# and AppleDecmpfs.kext's own reference, so it must NOT be used as a hard gate
# (a correctly stripped image can still show a high count from freed nodes).
decmpfs_bytes=$(grep -ao 'com.apple.decmpfs' "$out2" 2>/dev/null | wc -l | tr -d ' ') || true
echo "DECMPFS_BYTES: $decmpfs_bytes (informational; stale B-tree nodes may inflate this)"

# Authoritative gate: the files we cannot boot without must be real,
# uncompressed Mach-O images (or valid dyld caches). This runs WHILE the final
# volume is still mounted, so it actually inspects the bytes -- a passed xattr
# check is NOT enough, and flag/resource-fork compression survives xattr -d and
# still trips EOPNOTSUPP(45) on /sbin/launchd. Verify the ACTUAL bytes.
gate_fail=0
check_macho() {
	local p="$1" magic
	[ -e "$p" ] || return 0
	magic=$(sudo head -c 4 "$p" | xxd -p)
	case "$magic" in
		feedface|feedfacf|cffaedfe|cefaedfe|cafebabe|bebafeca) return 0 ;;
		*) echo "ERROR: $p is not a valid Mach-O (magic=$magic)" >&2; return 1 ;;
	esac
}
for probe in "$omp/sbin/launchd" "$omp/bin/launchd" "$omp/usr/libexec/launchd"; do
	[ -e "$probe" ] || continue
	if ! check_macho "$probe"; then gate_fail=1; fi
done
dsc="$omp/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"
if [ ! -f "$dsc" ] && [ -f "$omp/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64" ]; then
	dsc="$omp/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"
fi
if [ -f "$dsc" ] && ! head -c 11 "$dsc" | grep -q 'dyld_v1'; then
	echo "ERROR: dyld shared cache is not inflated" >&2
	gate_fail=1
fi
if [ "$gate_fail" -ne 0 ]; then
	echo "decmpfs gate FAILED -- image is broken" >&2
	exit 1
fi
echo "decmpfs gate passed"

echo "--- volume header (offset 1024) ---"
xxd -l 16 -s 1024 "$out2"

# Promote the final image: $out is what the caller / sparse step expects.
sudo umount "$omp"
hdiutil detach "$odev" -force
mv -f "$out2" "$out"
echo "final image written to $out"
ls -l "$out"

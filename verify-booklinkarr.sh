#!/usr/bin/env bash
# verify-booklinkarr.sh — syntax + logic check for the new booklinkarr.
# Run in the folder that contains linker/entrypoint.sh (or entrypoint.sh itself).
#
# Read-only: entrypoint.sh is never executed, nothing is written to the library.

SRC="linker/entrypoint.sh"
[ -f "$SRC" ] || SRC="entrypoint.sh"
if [ ! -f "$SRC" ]; then echo "entrypoint.sh not found"; exit 1; fi

echo "================================================================"
echo "1. SYNTAX CHECK (bash -n on the real entrypoint.sh)"
echo "================================================================"
if bash -n "$SRC"; then echo "  SYNTAX OK"; else echo "  SYNTAX FAILED"; exit 1; fi
echo ""

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

echo "================================================================"
echo "2. EXTRACT THE DEFINITIONS REGION"
echo "================================================================"
# Three ranges, skipping the "=== Validation ===" block (it would exit the
# verifier) and the main flow:
#   config + sanitizers + chapter map + validator + logging helpers
#   file operations + sync_series + scan_type + log dedup
awk '
    /^# === Configuration ===/ { f = 1 }
    /^# === Validation ===/      { f = 0 }
    /^# === File operations ===/ { f = 1 }
    /^# === Scan all types/      { f = 0 }
    f { print }
' "$SRC" > "$TMPD/lib.sh"
echo "  extracted lines: $(wc -l < "$TMPD/lib.sh")"
grep -n 'declare -A' "$TMPD/lib.sh" | sed 's/^/    /'
if bash -n "$TMPD/lib.sh"; then
    echo "  extracted region parses OK"
else
    echo "  extracted region FAILED to parse"; exit 1
fi
echo ""

log_info()  { echo "    INFO: $*"; }
log_warn()  { echo "    WARN: $*"; }
log_error() { echo "    ERROR: $*" >&2; }

# Point the cache dirs at the temp dir so the verifier never writes to /var/lib.
export CACHE_DIR="$TMPD/cache"

# shellcheck disable=SC1090
source "$TMPD/lib.sh" || { echo "  Could not source extracted functions"; exit 1; }
echo "  CHAP_DST: $(declare -p CHAP_DST 2>&1 | head -c 120)"
echo ""

SRC_ROOT="/home/carter117chief/media-drive/data/book-downloads"
DST_ROOT="/home/carter117chief/media-drive/data/media/books"
TYPES="mangas comics web-novels light-novels webtoons"
all_book_dirs() {
    local t
    for t in $TYPES; do
        [ -d "$SRC_ROOT/$t" ] || continue
        find "$SRC_ROOT/$t" -mindepth 2 -maxdepth 2 -type d 2>/dev/null
    done
}

echo "================================================================"
echo "2b. LITERAL PREFIX STRIPPING (glob-special directory names)"
echo "================================================================"
# A directory name containing [ ] * ? must be matched LITERALLY when
# stripping the book-dir prefix. Otherwise the prefix match fails, the whole
# absolute path survives, and the chapter name ends up empty
# ("bad array subscript").
pfail=0
pcheck() {
    local base="$1" expect="$2" got
    local src="/data/book-downloads/light-novels/Site/$base"
    local f="$src/Some Chapter/v01.epub"
    got="${f#"$src"/}"
    if [ "$got" = "$expect" ]; then
        echo "    OK   $base"
    else
        echo "    FAIL $base -> got '$got', want '$expect'"
        pfail=1
    fi
}
pcheck "Naruto Novels [VIZ Media] [LuCaZ]" "Some Chapter/v01.epub"
pcheck "Plain Book Name"                     "Some Chapter/v01.epub"
pcheck "Book (2024) [Digital]"               "Some Chapter/v01.epub"
pcheck "Starship*Odyssey"                     "Some Chapter/v01.epub"
pcheck "Question?Mark"                        "Some Chapter/v01.epub"
echo ""

echo "================================================================"
echo "3. FIXTURE RUN"
echo "================================================================"
FIX="$TMPD/fix"
mkdir -p "$FIX/book"
mk() { mkdir -p "$FIX/book/$1"; }
mk "Atsumaru (EN)_Series_Alpha_Episode 1 S1"
mk "Atsumaru (EN)_Series_Alpha_Episode 2 S1"
mk "Atsumaru (EN)_Series_Alpha_Episode 2.5 S1"
mk "Atsumaru (EN)_Series_Alpha_Episode 3 S1"
mk "Atsumaru (EN)_Series_Alpha_Episode 1 S2"
mk "Atsumaru (EN)_Series_Alpha_Episode 2 S2"
mk "Atsumaru (EN)_Series_Alpha_Spin-off 1"
mk "Atsumaru (EN)_Series_Alpha_Spin-off 2"
mk "Atsumaru (EN)_Series_Beta_Chapter 1 S1"

echo "  chapter dirs on disk: $(find "$FIX/book" -mindepth 1 -maxdepth 1 -type d | wc -l)"
echo ""
echo "  --- parse_chapter_name direct test ---"
parse_chapter_name "Atsumaru (EN)_Series_Alpha_Episode 12 S2"
echo "    CH_TYPE=[$CH_TYPE] CH_NUM=[$CH_NUM] CH_SEASON=[$CH_SEASON] CH_FRAC=[$CH_FRAC] CH_SIDE=[$CH_SIDESTORY]"
echo ""

build_chapter_map "$FIX/book" 2>/dev/null
echo "  build_chapter_map exit: $?"
echo ""
echo "  --- resulting map ---"
if [ "${#CHAP_DST[@]}" -eq 0 ]; then
    echo "    (EMPTY — map was not populated)"
else
    for k in "${!CHAP_DST[@]}"; do
        printf '    %-46s -> %s\n' "$(echo "$k" | sed 's/Atsumaru (EN)_Series_//')" "${CHAP_DST["$k"]}"
    done | sort
fi
echo ""
echo "  --- expectations ---"
fail=0
expect() {
    local src="$1" want="$2"
    local got="${CHAP_DST["$src"]:-<MISSING>}"
    if [ "$got" = "$want" ]; then
        echo "    OK   $(echo "$src" | sed 's/Atsumaru (EN)_Series_//') -> $got"
    else
        echo "    FAIL $(echo "$src" | sed 's/Atsumaru (EN)_Series_//') -> got '$got', want '$want'"
        fail=1
    fi
}
expect "Atsumaru (EN)_Series_Alpha_Episode 1 S1"  "Season 1/Episode 1"
expect "Atsumaru (EN)_Series_Alpha_Episode 2 S1"  "Season 1/Episode 2"
expect "Atsumaru (EN)_Series_Alpha_Episode 2.5 S1" "Season 1/Episode 2.5"
expect "Atsumaru (EN)_Series_Alpha_Episode 3 S1"  "Season 1/Episode 3"
expect "Atsumaru (EN)_Series_Alpha_Episode 1 S2"  "Season 2/Episode 4"
expect "Atsumaru (EN)_Series_Alpha_Episode 2 S2"  "Season 2/Episode 5"
expect "Atsumaru (EN)_Series_Alpha_Spin-off 1"    "Spin-off 6"
expect "Atsumaru (EN)_Series_Alpha_Spin-off 2"    "Spin-off 7"

A="Atsumaru (EN)_Series_Alpha_Episode 1 S1"
B="Atsumaru (EN)_Series_Beta_Chapter 1 S1"
a_mapped="${CHAP_DST["$A"]:-<none>}"
b_mapped="${CHAP_DST["$B"]:-<none>}"
a_skip="${CHAP_SKIP["$A"]:-}"
b_skip="${CHAP_SKIP["$B"]:-}"
if [ "$a_mapped" = "Season 1/Episode 1" ] && [ "$b_mapped" = "<none>" ] && [ -n "$b_skip" ]; then
    echo "    OK   tie resolved: Alpha wins, Beta superseded"
elif [ "$b_mapped" = "Season 1/Episode 1" ] && [ "$a_mapped" = "<none>" ] && [ -n "$a_skip" ]; then
    echo "    OK   tie resolved: Beta wins, Alpha superseded"
else
    echo "    FAIL tie not resolved (a='$a_mapped' skip='$a_skip' / b='$b_mapped' skip='$b_skip')"
    fail=1
fi

dupe=$(for k in "${!CHAP_DST[@]}"; do echo "${CHAP_DST["$k"]}"; done | sort | uniq -d)
if [ -z "$dupe" ]; then echo "    OK   no duplicate destination paths"
else echo "    FAIL duplicate destination paths: $dupe"; fail=1; fi

if for k in "${!CHAP_DST[@]}"; do echo "${CHAP_DST["$k"]}"; done | grep -q '(.*)'; then
    echo "    FAIL a destination path contains a locale tag"; fail=1
else
    echo "    OK   no locale tags in destination paths"
fi
echo ""

echo "================================================================"
echo "3b. CHAPTER TITLE PRESERVATION"
echo "================================================================"
FIX2="$TMPD/fix2"
mkdir -p "$FIX2/book"
mkdir -p "$FIX2/book/Atsumaru (EN)_Series_Alpha_Chapter 1_Tragedy"
mkdir -p "$FIX2/book/Atsumaru (EN)_Series_Alpha_Chapter 2_Oddity"
build_chapter_map "$FIX2/book" 2>/dev/null
tcheck() {
    local src="$1" want="$2"
    local got="${CHAP_DST["$src"]:-<MISSING>}"
    if [ "$got" = "$want" ]; then
        echo "    OK   $got"
    else
        echo "    FAIL got '$got', want '$want'"
        fail=1
    fi
}
tcheck "Atsumaru (EN)_Series_Alpha_Chapter 1_Tragedy" "Chapter 1_Tragedy"
tcheck "Atsumaru (EN)_Series_Alpha_Chapter 2_Oddity"  "Chapter 2_Oddity"

FIX3="$TMPD/fix3"
mkdir -p "$FIX3/book"
mkdir -p "$FIX3/book/Atsumaru (EN)_Series_Alpha_Episode 1_Tragedy S1"
mkdir -p "$FIX3/book/Atsumaru (EN)_Series_Alpha_Episode 2_Oddity S1"
mkdir -p "$FIX3/book/Atsumaru (EN)_Series_Alpha_Episode 1_Extra S2"
build_chapter_map "$FIX3/book" 2>/dev/null
tcheck "Atsumaru (EN)_Series_Alpha_Episode 1_Tragedy S1" "Season 1/Episode 1_Tragedy"
tcheck "Atsumaru (EN)_Series_Alpha_Episode 2_Oddity S1"  "Season 1/Episode 2_Oddity"
tcheck "Atsumaru (EN)_Series_Alpha_Episode 1_Extra S2"    "Season 2/Episode 3_Extra"

FIX4="$TMPD/fix4"
mkdir -p "$FIX4/book"
mkdir -p "$FIX4/book/Atsumaru (EN)_Series_Alpha_Episode 1_S1_Tragedy"
mkdir -p "$FIX4/book/Atsumaru (EN)_Series_Alpha_Episode 2_S1_Oddity"
mkdir -p "$FIX4/book/Atsumaru (EN)_Series_Alpha_Episode 1_S2_Extra"
build_chapter_map "$FIX4/book" 2>/dev/null
tcheck "Atsumaru (EN)_Series_Alpha_Episode 1_S1_Tragedy" "Season 1/Episode 1_Tragedy"
tcheck "Atsumaru (EN)_Series_Alpha_Episode 2_S1_Oddity"  "Season 1/Episode 2_Oddity"
tcheck "Atsumaru (EN)_Series_Alpha_Episode 1_S2_Extra"    "Season 2/Episode 3_Extra"
echo ""

echo "================================================================"
echo "4. VALIDATOR TEST (valid / truncated / empty / wrong-magic)"
echo "================================================================"
VD="$TMPD/valid"; VD2="$TMPD/truncated"; VD3="$TMPD/empty"; VD4="$TMPD/wrongmagic"
mkdir -p "$VD" "$VD2" "$VD3" "$VD4"
printf 'RIFF\x02\x01\x00\x00WEBP' > "$VD/good.webp"
head -c 254 /dev/zero >> "$VD/good.webp"
printf 'RIFF\x02\x01\x00\x00WEBP' > "$VD2/short.webp"
head -c 100 /dev/zero >> "$VD2/short.webp"
: > "$VD3/empty.webp"
printf 'NOTAWEBPFILE' > "$VD4/bogus.webp"
echo "  good.webp size: $(stat -c %s "$VD/good.webp")  (declared $((258 + 8)))"

vfail=0
vcheck() {
    local dir="$1" want="$2" label="$3" got
    if validate_chapter_files "$dir" "testbook" "$label" >/dev/null 2>&1; then got="PASS"; else got="FAIL"; fi
    if [ "$got" = "$want" ]; then
        echo "    OK   $label -> $got"
    else
        echo "    FAIL $label -> $got (expected $want)"
        vfail=1
    fi
}
vcheck "$VD"  PASS "valid webp"
vcheck "$VD2" FAIL "truncated webp"
vcheck "$VD3" FAIL "empty file"
vcheck "$VD4" FAIL "wrong magic bytes"
echo ""

echo "================================================================"
echo "4b. LEGACY FOLDER CLEANUP"
echo "================================================================"
lfail=0
CL="$TMPD/cleanup"
mkdir -p "$CL/src/Book_Alpha_Episode 5" "$CL/src/Book_Alpha_Episode 9"
mkdir -p "$CL/dst/Episode 5" "$CL/dst/Episode 9"
echo hi > "$CL/src/Book_Alpha_Episode 5/001.webp"
ln "$CL/src/Book_Alpha_Episode 5/001.webp" "$CL/dst/Episode 5/001.webp"
echo unique > "$CL/dst/Episode 9/manual.txt"

CHAP_DST=()
CHAP_DST["Book_Alpha_Episode 5"]="Chapter 5"
CHAP_DST["Book_Alpha_Episode 9"]="Chapter 9"
cleanup_legacy_paths "$CL/src" "$CL/dst" >/dev/null 2>&1

if [ -d "$CL/dst/Episode 5" ]; then
    echo "    FAIL legacy folder with only hardlinks was NOT removed"
    lfail=1
else
    echo "    OK   legacy folder with only hardlinks removed"
fi
if [ -d "$CL/dst/Episode 9" ]; then
    echo "    OK   legacy folder with a unique file kept"
else
    echo "    FAIL legacy folder with a unique file was removed"
    lfail=1
fi
echo ""

echo "================================================================"
echo "4c. VALIDATION 'LOG ONCE' BEHAVIOUR"
echo "================================================================"
# A corrupt chapter must be reported once, then skipped silently on later
# scans until its source changes.
# NOTE: sync_series takes the BOOK directory; the chapter is a subdirectory of
# it. Passing the chapter dir directly would leave the chapter map empty and
# validation would never run.
CF="$TMPD/corruptbook"
mkdir -p "$CF/src/Book/Book_Alpha_Chapter 1"
printf 'NOTAWEBPFILE' > "$CF/src/Book/Book_Alpha_Chapter 1/001.webp"
out1=$(sync_series "$CF/src/Book" "$CF/dst" 2>&1)
out2=$(sync_series "$CF/src/Book" "$CF/dst" 2>&1)
c1=$(printf '%s' "$out1" | grep -c "Corrupt chapter")
c2=$(printf '%s' "$out2" | grep -c "Corrupt chapter")
if [ "$c1" -eq 1 ] && [ "$c2" -eq 0 ]; then
    echo "    OK   reported once, then skipped silently"
else
    echo "    FAIL first call reported $c1, second reported $c2 (expected 1 then 0)"
    lfail=1
fi
# The chapter must not have been linked.
if [ -d "$CF/dst/Chapter 1" ]; then
    echo "    FAIL corrupt chapter was linked to the destination"
    lfail=1
else
    echo "    OK   corrupt chapter was not linked"
fi
# Touching the source must make it report again.
printf 'ALSO NOT A WEBP' > "$CF/src/Book/Book_Alpha_Chapter 1/002.webp"
out3=$(sync_series "$CF/src/Book" "$CF/dst" 2>&1)
c3=$(printf '%s' "$out3" | grep -c "Corrupt chapter")
if [ "$c3" -eq 1 ]; then
    echo "    OK   reports again after the source changes"
else
    echo "    FAIL reports $c3 times after the source changed (expected 1)"
    lfail=1
fi
echo ""

echo "================================================================"
echo "4d. BOOK WITH NO CHAPTER SUBDIRS (whole-book validation)"
echo "================================================================"
# Files sitting directly in the book directory have no chapter to hang
# validation off, so the book itself is validated as one unit.
BF="$TMPD/flatbook"
mkdir -p "$BF/src"
printf 'NOTAWEBPFILE' > "$BF/src/v01.epub"
outf=$(sync_series "$BF/src" "$BF/dst" 2>&1)
if printf '%s' "$outf" | grep -q "Corrupt chapter"; then
    echo "    OK   flat book validated and refused"
else
    echo "    FAIL flat book was not validated"
    lfail=1
fi
if [ -e "$BF/dst/v01.epub" ]; then
    echo "    FAIL flat book file was linked despite failing validation"
    lfail=1
else
    echo "    OK   flat book file was not linked"
fi
echo ""

echo "================================================================"
echo "4e. CACHE HIT MUST NOT SKIP A BOOK WITH A MISSING DESTINATION"
echo "================================================================"
# The destination can be emptied or left at an old path while the source is
# untouched. The book-level cache must not skip the book in that case.
CH="$TMPD/cachetest"
mkdir -p "$CH/src/Book/Book_Alpha_Chapter 1"
cp "$VD/good.webp" "$CH/src/Book/Book_Alpha_Chapter 1/001.webp"
sync_series "$CH/src" "$CH/dst" >/dev/null 2>&1
if [ -e "$CH/dst/Chapter 1/001.webp" ]; then
    echo "    OK   first sync linked the chapter"
else
    echo "    FAIL first sync did not link the chapter"
    lfail=1
fi
# Empty the destination, leave the source alone — simulates a naming change
# stranding a book, or the destination being deleted underneath us.
rm -rf "$CH/dst"
sync_series "$CH/src" "$CH/dst" >/dev/null 2>&1
if [ -e "$CH/dst/Chapter 1/001.webp" ]; then
    echo "    OK   destination re-created even though the source was unchanged"
else
    echo "    FAIL destination was NOT re-created (cache hit skipped it)"
    lfail=1
fi
echo ""

if [ -d "$SRC_ROOT" ] && [ -d "$DST_ROOT" ]; then
    printf '  %-34s %8s %8s\n' "book" "new" "orphan"
    printf '  %-34s %8s %8s\n' "----------------------------------" "--------" "--------"
    while IFS= read -r bd; do
        rel="${bd#$SRC_ROOT/}"
        t="${rel%%/*}"
        bn=$(basename "$bd")
        db="$DST_ROOT/$t/$(sanitize_book_name "$bn")"
        [ -d "$db" ] || continue
        build_chapter_map "$bd" 2>/dev/null
        for k in "${!CHAP_DST[@]}"; do echo "${CHAP_DST["$k"]}"; done | sort > "$TMPD/c"
        find "$db" -mindepth 1 -maxdepth 2 -type d 2>/dev/null \
            | sed "s|^$db/||" | grep -vE '^Season [0-9]+$' | sort > "$TMPD/e"
        newc=$(comm -23 "$TMPD/c" "$TMPD/e" | wc -l)
        gone=$(comm -13 "$TMPD/c" "$TMPD/e" | wc -l)
        if [ "$newc" -gt 0 ] || [ "$gone" -gt 0 ]; then
            printf '  %-34s %8s %8s\n' "$bn" "$newc" "$gone"
        fi
    done < <(all_book_dirs)
    echo ""
    echo "  'new'    = chapter folders that would be created"
    echo "  'orphan' = existing folders the new naming replaces (now auto-removed)"
else
    echo "  library not found — skipped"
fi
echo ""

echo "================================================================"
echo "6. REAL LIBRARY CHECK"
echo "================================================================"
if [ -d "$SRC_ROOT" ]; then
    dupbooks=0; checked=0
    while IFS= read -r bd; do
        build_chapter_map "$bd" 2>/dev/null
        checked=$((checked + 1))
        d=$(for k in "${!CHAP_DST[@]}"; do echo "${CHAP_DST["$k"]}"; done | sort | uniq -d)
        if [ -n "$d" ]; then
            dupbooks=$((dupbooks + 1))
            echo "  DUPLICATES in $bd:"
            echo "$d" | head -5 | sed 's/^/      /'
        fi
        if [ "$bd" = "$(all_book_dirs | grep -i jungle | head -1)" ]; then
            echo ""
            echo "  --- Jungle Juice destination paths ---"
            for k in "${!CHAP_DST[@]}"; do echo "${CHAP_DST["$k"]}"; done | sort -V > "$TMPD/jj"
            echo "  total mapped: ${#CHAP_DST[@]}"
            head -5 "$TMPD/jj" | sed 's/^/    /'
            echo "    ..."
            tail -5 "$TMPD/jj" | sed 's/^/    /'
        fi
    done < <(all_book_dirs)
    echo ""
    echo "  books checked: $checked"
    [ "$dupbooks" = "0" ] && echo "  no duplicate destination paths" || echo "  $dupbooks book(s) with duplicates"
else
    echo "  library source not found"
fi

echo ""
echo "================================================================"
echo "SUMMARY"
echo "================================================================"
[ "$fail" = "0" ] && echo "  naming logic: OK" || echo "  naming logic: FAILED"
[ "$vfail" = "0" ] && echo "  validator:    OK" || echo "  validator:    FAILED"
[ "$lfail" = "0" ] && echo "  cleanup:      OK" || echo "  cleanup:      FAILED"
[ "$pfail" = "0" ] && echo "  prefix strip: OK" || echo "  prefix strip: FAILED"

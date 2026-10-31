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
awk '
    /^# === Path sanitization/ { f = 1 }
    /^# === Validation ===/      { f = 0 }
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

# shellcheck disable=SC1090
source "$TMPD/lib.sh" || { echo "  Could not source extracted functions"; exit 1; }
echo "  CHAP_DST: $(declare -p CHAP_DST 2>&1 | head -c 120)"
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

# Run in the CURRENT shell so the map survives for inspection.
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
echo "4. VALIDATOR TEST (valid / truncated / empty / wrong-magic)"
echo "================================================================"
VD="$TMPD/valid"; VD2="$TMPD/truncated"; VD3="$TMPD/empty"; VD4="$TMPD/wrongmagic"
mkdir -p "$VD" "$VD2" "$VD3" "$VD4"
# A RIFF/WEBP file: 'RIFF' + size(4, LITTLE endian) + 'WEBP' + payload.
# size must equal filesize-8. Using 258 (0x00000102 -> bytes 02 01 00 00)
# so a big-endian read would give a wildly different number.
printf 'RIFF\x02\x01\x00\x00WEBP' > "$VD/good.webp"
head -c 254 /dev/zero >> "$VD/good.webp"        # total 266 = 258 + 8  ✓
# Same header but only 100 bytes of payload -> declared 266, actual 112 -> truncated.
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
echo "5. REAL LIBRARY CHECK"
echo "================================================================"
SRC_ROOT="/home/carter117chief/media-drive/data/book-downloads"
TYPES="mangas comics web-novels light-novels webtoons"
all_book_dirs() {
    local t
    for t in $TYPES; do
        [ -d "$SRC_ROOT/$t" ] || continue
        find "$SRC_ROOT/$t" -mindepth 2 -maxdepth 2 -type d 2>/dev/null
    done
}
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

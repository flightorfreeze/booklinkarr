#!/usr/bin/env bash
# Booklinkarr v0.6 - hardlinks book downloads into the books library
# v0.6: PUID/PGID support (run as host user, no sudo for file management);
#       path sanitization for Kavita parser compat (strips digits from series/
#       chapter folder names so "After 4000 Years" doesn't trigger Kavita's
#       number-as-chapter parser bug).
# See docs/superpowers/specs/2026-10-07-booklinkarr-redesign-design.md
set -euo pipefail

# === PUID/PGID: drop privileges to match host user ===
# When PUID != 0 and we're root, create/use a user matching the requested IDs,
# chown the data dirs, then re-exec this script as that user.
# Default PUID=0 means "run as root" (back-compat with v0.5 behavior).
PUID="${PUID:-0}"
PGID="${PGID:-0}"

if [ "$(id -u)" = "0" ] && [ "$PUID" != "0" ] && [ "$PGID" != "0" ]; then
    # Create or modify the group/user to match the requested IDs.
    # groupmod/useradd -o allows non-unique IDs (e.g. reusing 1000).
    if ! groupmod -o -g "$PGID" booklinkarr 2>/dev/null; then
        groupadd -o -g "$PGID" booklinkarr
    fi
    if ! usermod -o -u "$PUID" -g "$PGID" -d /var/lib/booklinkarr -s /bin/bash booklinkarr 2>/dev/null; then
        useradd -o -u "$PUID" -g "$PGID" -d /var/lib/booklinkarr -s /bin/bash booklinkarr
    fi

    # Chown the data dirs we need to write to. Always runs (idempotent).
    chown -R booklinkarr:booklinkarr /var/lib/booklinkarr /app/data 2>/dev/null || true

    # Re-exec this script as the non-root user.
    exec gosu booklinkarr "$0" "$@"
fi

# === Configuration ===
SRC_ROOT="${SRC_ROOT:-/source}"
DST_ROOT="${DST_ROOT:-/target}"
SCAN_INTERVAL="${SCAN_INTERVAL:-600}"
TYPES=("mangas" "comics" "web-novels" "light-novels" "webtoons")

# === Per-book scan cache (fast path) ===
# Cache files live at $STAT_CACHE_DIR/<dst>.cache (one per book). The file's
# mtime marks the last sync time. A "cache hit" in sync_series means the cache
# file exists, is younger than STAT_CACHE_MAX_AGE, and no source file is newer
# than the cache file — in which case we skip the per-file iteration entirely.
#
# What this catches (triggers slow path):
#   - New chapter folders added (a file inside has newer mtime)
#   - In-chapter file modifications or additions (newer mtime)
#
# What this does NOT catch (cache hits, relies on PURGE_ORPHANS for safety):
#   - Source deletions (file count drops; mtime unchanged)
#   - File additions with manually-preserved old mtimes (e.g., `cp -p`)
# PURGE_ORPHANS catches orphan dst files via inode comparison on every rescan,
# so a stale cache hit doesn't cause permanent data drift.
STAT_CACHE_DIR="${CACHE_DIR:-/var/lib/booklinkarr}/scan_cache"
STAT_CACHE_MAX_AGE="${STAT_CACHE_MAX_AGE:-604800}"  # 7 days, safety net

# === Corrupt / empty file detection ===
# When enabled, a chapter whose files look corrupt (truncated, wrong magic
# bytes) or empty is NOT linked at all and an error is logged, so the gap is
# visible in the library and the user knows to re-download that chapter.
# Checks run only for chapters that are about to be linked.
VALIDATE_FILES="${VALIDATE_FILES:-1}"

# Marker files for chapters that failed validation, so the error is reported
# once rather than on every rescan.
FAILED_DIR="${CACHE_DIR:-/var/lib/booklinkarr}/failed"

# === Path sanitization (Kavita parser compat + chapter rename) ===
# Two separate functions because book names and chapter names want different
# transforms:
#   - BOOK folder names get digits stripped (Kavita's parser extracts digits
#     from folder names and treats them as chapter numbers — "The Archmage
#     Returns After 4000 Years" would be parsed as chapter 4000 with 3999
#     phantom predecessors).
#   - CHAPTER folder names get the scanlator/series prefix stripped but keep
#     the chapter TYPE identifier and number (Chapter N, Episode N, Blank N,
#     Volume N, plus abbreviation normalizations).
#
# Filenames are NOT sanitized (extensions and numeric ordering preserved).
#
# Booklinkarr must NEVER create an unsanitized dst directory for a book or
# chapter — that would orphan the existing dst and silently double the library.

# Sanitize a BOOK folder name: strip digits to dodge Kavita's parser bug.
# "The Archmage Returns After 4000 Years" -> "The Archmage Returns After Years"
sanitize_book_name() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "unknown_series"
        return
    fi
    echo "$name" | tr -d '0-9' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# Sanitize a CHAPTER folder name: strip scanlator/series prefix while preserving
# the chapter TYPE identifier. Recognized types (full → dst form):
#   Chapter       -> Chapter N
#   Episode       -> Episode N
#   Blank         -> Blank N
#   Volume        -> Volume N
#   Vol / Vol.    -> Volume N      (abbreviation normalized)
#   Ep. / Ep      -> Episode N     (abbreviation normalized)
#   Ch. / Ch      -> Chapter N     (abbreviation normalized)
# Example: "Atsumaru (EN)_The Devil Butler_Alpha_Episode 5" -> "Episode 5"
# This keeps each chapter uniquely addressable in dst (without it, all 301
# episodes sanitized to the same string and merged into one folder).
# Falls back to trimming whitespace only (no digit-strip) when no type
# identifier is found — the digit-strip fallback was the Devil Butler merge bug.
sanitize_dir_name() {
    # IMPORTANT: bash's case-pattern parser chokes on glob patterns that contain
    # a literal space before the closing `)` — it splits "Word *" and sees the
    # second `*` as an unexpected token. Every pattern below is checked to have
    # NO space between the last glob char and the closing `)`.
    local name="$1"
    case "$name" in
        *Chapter*) echo "Chapter${name#*Chapter}"; return ;;
        *Episode*) echo "Episode${name#*Episode}"; return ;;
        *Blank*)   echo "Blank${name#*Blank}";     return ;;
        *Volume*)  echo "Volume${name#*Volume}";   return ;;
        *Vol.*)    echo "Volume${name#*Vol.}";     return ;;  # Vol. 1 -> "Volume 1"
        *Vol*)     echo "Volume${name#*Vol}";      return ;;  # Vol 1 -> "Volume 1"
        *Ep.*)     echo "Episode${name#*Ep.}";     return ;;  # Ep. 1 -> "Episode 1"
        *Ep*)      echo "Episode${name#*Ep}";      return ;;  # Ep 1 -> "Episode 1"
        *Ch.*)     echo "Chapter${name#*Ch.}";     return ;;  # Ch. 1 -> "Chapter 1"
        *Ch*)      echo "Chapter${name#*Ch}";      return ;;  # Ch 1 -> "Chapter 1"
    esac
    # No chapter type identifier found — leave name as-is, just trim whitespace.
    echo "$name" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# === Chapter folder name parsing (per-book) ===
#
# Source chapter folder names look like:
#   "Atsumaru (EN)_Jungle Juice_Alpha_Episode 12 S2"
#   "Atsumaru (EN)_Jungle Juice_Alpha_Spin-off 1"
#   "Atsumaru (EN)_Jungle Juice_Delta_Chapter 321"
#
# We extract the type word, the chapter number (may be decimal), a trailing
# season marker, and the "residual" text (everything that is neither the type
# word nor the number). The residual's word count is what tells a canonical
# chapter apart from a side story that happens to carry the same number.

# Chapter type keywords, matched in this order (first match wins). A keyword
# only counts as a type when a number follows it.
CH_KW=("Side Story" "Spin-off" "Bonus" "Omake" "Special" "Extra"
       "Chapter" "Episode" "Blank" "Volume"
       "Vol." "Vol " "Ep." "Ep " "Ch." "Ch ")
# Canonical destination name for each keyword.
CH_CANON=("Side Story" "Spin-off" "Bonus" "Omake" "Special" "Extra"
           "Chapter" "Episode" "Blank" "Volume"
           "Volume" "Volume" "Episode" "Episode" "Chapter" "Chapter")
# 1 = the keyword marks a side story rather than a main-sequence chapter.
CH_SIDE=(1 1 1 1 1 1 0 0 0 0 0 0 0 0 0 0)

# Parse results (globals).
CH_TYPE=""
CH_NUM=""
CH_SEASON=""
CH_FRAC=""
CH_RESIDUAL=""
CH_SUFFIX=""
CH_SIDESTORY=0
CH_WORDS=0

# Parse the tail of a chapter name (everything after the type + number) for a
# season marker and a chapter title. The season may sit at the end of the tail
# or in front of the title:
#   " S2"         -> season 2, title ""
#   "_S1"         -> season 1, title ""
#   "_S1_Tragedy" -> season 1, title "_Tragedy"
#   "_Tragedy"    -> no season, title "_Tragedy"
parse_chapter_tail() {
    local tail="$1"
    CH_SEASON=""
    CH_SUFFIX="$tail"
    if [[ "$tail" =~ (^|[_[:space:]])(Season|Se|S)([[:space:]_.]*)([0-9]+)([_[:space:]]|$) ]]; then
        local m="${BASH_REMATCH[0]}"
        local trail="${BASH_REMATCH[5]}"
        local pre="${tail%%"$m"*}"
        local post="${tail#*"$m"}"
        CH_SEASON="${BASH_REMATCH[4]}"
        CH_SUFFIX="$pre$trail$post"
    fi
}

# Parse a chapter folder name into the globals above.
parse_chapter_name() {
    local name="$1"
    local work="$name"

    CH_TYPE=""
    CH_NUM=""
    CH_SEASON=""
    CH_FRAC=""
    CH_RESIDUAL="$name"
    CH_SUFFIX=""
    CH_SIDESTORY=0
    CH_WORDS=0

    # --- type keyword plus the number that follows it ---
    local i kw after before sep int frac rem off
    for i in "${!CH_KW[@]}"; do
        kw="${CH_KW[$i]}"
        case "$work" in
            *"$kw"*) ;;
            *) continue ;;
        esac
        after="${work#*"$kw"}"
        if [[ "$after" =~ ^([[:space:]_.-]*)([0-9]+)(\.[0-9]+)? ]]; then
            sep="${BASH_REMATCH[1]}"
            int="${BASH_REMATCH[2]}"
            frac="${BASH_REMATCH[3]}"
            before="${work%*"$kw"*}"
            off=$(( ${#sep} + ${#int} + ${#frac} ))
            rem="${after:$off}"
            CH_TYPE="${CH_CANON[$i]}"
            CH_NUM="$int"
            CH_FRAC=""
            if [ -n "$frac" ]; then
                CH_NUM="$int$frac"
                CH_FRAC="${frac#*.}"
            fi
            CH_SIDESTORY="${CH_SIDE[$i]}"
            # CH_RESIDUAL is the text BEFORE the type keyword. It is used to
            # tell a canonical chapter apart from a side story that carries
            # extra words ("Vanessa's story Chapter 1" vs "Chapter 1").
            # Everything after the number is the chapter TITLE and season, and
            # is handled by parse_chapter_tail so that it survives into the
            # destination name ("Chapter 1_Tragedy" stays "Chapter 1_Tragedy").
            CH_RESIDUAL="$before"
            parse_chapter_tail "$rem"
            CH_WORDS=$(printf '%s' "$CH_RESIDUAL" | wc -w)
            return 0
        fi
    done

    # No recognised type keyword. Keep the bare number if the name ends in one
    # (e.g. "Atsumaru (EN)_Black Butler_87" -> number 87).
    if [[ "$work" =~ ([0-9]+)(\.[0-9]+)?$ ]]; then
        int="${BASH_REMATCH[1]}"
        frac="${BASH_REMATCH[2]}"
        CH_NUM="$int"
        CH_FRAC=""
        if [ -n "$frac" ]; then
            CH_NUM="$int$frac"
            CH_FRAC="${frac#*.}"
        fi
        CH_TYPE=""
        CH_RESIDUAL="$work"
        CH_WORDS=$(printf '%s' "$CH_RESIDUAL" | wc -w)
    fi
    return 0
}

# === Per-book chapter map ===
# Built once per book, before the per-file loop.
#
#   CHAP_DST[<src chapter dir name>]   = destination path relative to the book dst
#   CHAP_SKIP[<src chapter dir name>]  = "1" if the chapter is superseded and skipped
declare -A CHAP_DST
declare -A CHAP_SKIP

# Build the chapter map for one book directory.
build_chapter_map() {
    local src="$1"

    CHAP_DST=()
    CHAP_SKIP=()

    local -a nm=() ty=() num=() sea=() frc=() sid=() wrd=() mtm=() sfx=()
    local n=0 dir name i

    while IFS= read -r dir; do
        name=$(basename "$dir")
        parse_chapter_name "$name"
        nm[$n]="$name"
        ty[$n]="$CH_TYPE"
        num[$n]="$CH_NUM"
        sea[$n]="$CH_SEASON"
        frc[$n]="$CH_FRAC"
        sid[$n]="$CH_SIDESTORY"
        wrd[$n]="$CH_WORDS"
        sfx[$n]="$CH_SUFFIX"
        mtm[$n]=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
        n=$((n + 1))
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    [ "$n" -eq 0 ] && return 0

    # --- per-book type normalisation: Chapter vs Episode ---
    # If a series mixes the two, the whole series adopts the more prevalent one.
    local c_chapter=0 c_episode=0 canon_type=""
    for ((i = 0; i < n; i++)); do
        case "${ty[$i]}" in
            Chapter) c_chapter=$((c_chapter + 1)) ;;
            Episode) c_episode=$((c_episode + 1)) ;;
        esac
    done
    if [ "$c_chapter" -gt 0 ] && [ "$c_episode" -gt 0 ]; then
        if [ "$c_chapter" -ge "$c_episode" ]; then
            canon_type="Chapter"
        else
            canon_type="Episode"
        fi
        for ((i = 0; i < n; i++)); do
            case "${ty[$i]}" in
                Chapter|Episode) ty[$i]="$canon_type" ;;
            esac
        done
    fi

    # --- regime: does the book carry any season markers? ---
    local has_season=0 min_season=0
    for ((i = 0; i < n; i++)); do
        if [ -n "${sea[$i]}" ]; then
            has_season=1
            if [ "$min_season" -eq 0 ] || [ "${sea[$i]}" -lt "$min_season" ]; then
                min_season="${sea[$i]}"
            fi
        fi
    done

    # --- destination season and ordering bucket for each chapter ---
    # bucket 0 = prologue (chapter 0), 1 = main sequence, 2 = tail (unseasoned),
    # 3 = tail (side story).
    local -a dsea=() bucket=()
    for ((i = 0; i < n; i++)); do
        local s=0 b=2
        if [ -n "${num[$i]}" ] && [ "${num[$i]%%.*}" = "0" ]; then
            b=0
            if [ "$has_season" -eq 1 ]; then s=1; fi
        elif [ -n "${sea[$i]}" ]; then
            s="${sea[$i]}"
            b=1
        elif [ "$has_season" -eq 1 ] && [ "$min_season" -gt 1 ]; then
            # Seasons start above 1 — unseasoned chapters fill the gap.
            s=1
            b=1
        fi
        if [ "${sid[$i]}" = "1" ]; then
            b=3
            s=0
        fi
        dsea[$i]=$s
        bucket[$i]=$b
    done

    # --- sort keys ---
    local -a keys=()
    for ((i = 0; i < n; i++)); do
        local int="${num[$i]%%.*}"
        local fr="${frc[$i]}"
        if [ -z "$int" ]; then int=0; fi
        if [ -z "$fr" ]; then fr=0; fi
        keys[$i]=$(printf '%01d%04d%08d%03d\t%06d' \
            "${bucket[$i]}" "${dsea[$i]}" "$int" "$fr" "$i")
    done

    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "${keys[@]}" | LC_ALL=C sort)

    # --- how many distinct seasons (decides whether we nest under Season N/) ---
    local season_count=0
    local -A seen_season=()
    for ((i = 0; i < n; i++)); do
        local sv="${sea[$i]}"
        if [ -n "$sv" ] && [ -z "${seen_season[$sv]:-}" ]; then
            seen_season["$sv"]=1
            season_count=$((season_count + 1))
        fi
    done
    local nested=0
    if [ "$season_count" -ge 2 ]; then nested=1; fi

    # --- assign destinations ---
    # In a book with seasons every chapter is renumbered into one global
    # sequence; without seasons the source numbers are preserved and only
    # collisions are resolved.
    local counter=0
    local -a dest=() skip=()
    local idx=0 group_end winner loser
    local gkey gi w c

    while [ "$idx" -lt "$n" ]; do
        # The sort key zero-pads the index ("000008"), and bash would read a
        # leading zero as OCTAL when the value is used as an array subscript —
        # and "8" is not a valid octal digit. 10# forces base 10.
        gi="${sorted[$idx]##*$'\t'}"
        gi=$((10#${gi:-0}))
        # The bucket is part of the group key so that two chapters with the same
        # number but in different buckets (e.g. "Episode 5" and "Spin-off 5")
        # never get merged into one group.
        gkey="${bucket[$gi]}|${dsea[$gi]}|${num[$gi]}"

        # Collect the group (adjacent entries share bucket + season + number).
        group_end=$idx
        winner=$gi
        while [ "$group_end" -lt "$n" ]; do
            gi="${sorted[$group_end]##*$'\t'}"
            gi=$((10#${gi:-0}))
            if [ "${bucket[$gi]}|${dsea[$gi]}|${num[$gi]}" != "$gkey" ]; then break; fi
            if [ "$group_end" -gt "$idx" ]; then
                w="${wrd[$winner]}"
                c="${wrd[$gi]}"
                if [ "$c" -lt "$w" ]; then
                    winner=$gi
                elif [ "$c" -eq "$w" ]; then
                    if [ "${mtm[$gi]}" -gt "${mtm[$winner]}" ]; then
                        winner=$gi
                    elif [ "${mtm[$gi]}" -eq "${mtm[$winner]}" ] &&
                         [ "${nm[$gi]}" \< "${nm[$winner]}" ]; then
                        winner=$gi
                    fi
                fi
            fi
            group_end=$((group_end + 1))
        done

        # Assign the group's number.
        # A decimal chapter (83.5) hangs off the preceding integer and does not
        # advance the counter, so 83, 83.5, 84 stay 83, 83.5, 84.
        local assigned=""
        if [ "$has_season" -eq 1 ]; then
            local frac="${frc[$winner]}"
            local int="${num[$winner]%%.*}"
            if [ -n "$int" ] && [ "$int" = "0" ]; then
                # Prologue: chapter 0, counter stays at 0.
                assigned="$counter"
                if [ -n "$frac" ]; then assigned="$counter.$frac"; fi
            elif [ -n "$frac" ]; then
                assigned="$counter.$frac"
            else
                counter=$((counter + 1))
                assigned="$counter"
            fi
        else
            assigned="${num[$winner]}"
        fi

        # The winner takes the destination; the others are either superseded
        # (same chapter from another scanlator) or demoted to a side story
        # (a different chapter that carried the same number).
        # The chapter title (e.g. "_Tragedy") is carried over from the source.
        local wtype="${ty[$winner]}"
        local wsuf="${sfx[$winner]}"
        local dpath=""
        if [ -n "$wtype" ]; then
            dpath="$wtype $assigned$wsuf"
        else
            dpath="$assigned$wsuf"
        fi
        if [ "$nested" -eq 1 ] && [ "${dsea[$winner]}" != "0" ]; then
            dpath="Season ${dsea[$winner]}/$dpath"
        fi
        dest[$winner]="$dpath"

        # Losers.
        local l
        for ((l = idx; l < group_end; l++)); do
            if [ "$l" -eq "$idx" ]; then continue; fi
            gi="${sorted[$l]##*$'\t'}"
            gi=$((10#${gi:-0}))
            if [ "$gi" = "$winner" ]; then continue; fi
            if [ "${wrd[$gi]}" -gt "${wrd[$winner]}" ]; then
                # More descriptive than the canonical chapter -> side story.
                skip[$gi]=2
            else
                # Same shape -> the same chapter from another scanlator.
                skip[$gi]=1
            fi
        done

        idx=$group_end
    done

    # --- side stories get their numbers appended at the end of the book ---
    # The highest number already in use, taken from the source numbers (an
    # unseasoned book preserves them).
    local max_assigned=0
    for ((i = 0; i < n; i++)); do
        local v="${num[$i]%%.*}"
        if [ -n "$v" ] && [ "$v" -gt "$max_assigned" ] 2>/dev/null; then
            max_assigned="$v"
        fi
    done
    local side_count=0
    for ((i = 0; i < n; i++)); do
        if [ "${skip[$i]:-}" = "2" ]; then side_count=$((side_count + 1)); fi
    done
    if [ "$has_season" -eq 1 ]; then
        # Seasoned books: side stories take the next numbers after the sequence.
        for ((i = 0; i < n; i++)); do
            [ "${skip[$i]:-}" = "2" ] || continue
            counter=$((counter + 1))
            local st="${ty[$i]}"
            local sp="$counter"
            if [ -n "$st" ]; then
                dest[$i]="$st $sp${sfx[$i]}"
            else
                dest[$i]="$sp${sfx[$i]}"
            fi
            skip[$i]=0
        done
    else
        # Unseasoned books: side stories continue past the highest number used.
        for ((i = 0; i < n; i++)); do
            [ "${skip[$i]:-}" = "2" ] || continue
            max_assigned=$((max_assigned + 1))
            local st="${ty[$i]}"
            local sp="$max_assigned"
            if [ -n "$st" ]; then
                dest[$i]="$st $sp${sfx[$i]}"
            else
                dest[$i]="$sp${sfx[$i]}"
            fi
            skip[$i]=0
        done
    fi

    # --- publish the map ---
    for ((i = 0; i < n; i++)); do
        # Publish the skip flag first: a superseded chapter has no destination
        # of its own, so the "continue" below would otherwise drop the flag.
        if [ "${skip[$i]:-}" = "1" ]; then
            CHAP_SKIP["${nm[$i]}"]=1
        fi
        local d="${dest[$i]:-}"
        if [ -z "$d" ]; then continue; fi
        CHAP_DST["${nm[$i]}"]="$d"
    done
    return 0
}

# Remove destination folders that the current naming scheme replaces.
#
# When the naming scheme changes (e.g. a series mixes "Episode N" and
# "Chapter N" and gets normalised to one of them), the old folder would be
# left behind: its inodes still exist in the source, so PURGE_ORPHANS does
# not consider them orphans, and Kavita would show the chapter twice.
#
# For each chapter we compute the LEGACY destination name (what the previous
# sanitize_dir_name produced) and, if it differs from the new name, remove it.
# Safety: a legacy path is only removed when no chapter uses it under the new
# scheme, and only when every file in it is a hardlink (link count >= 2) —
# a file unique to the destination means something else put it there.
cleanup_legacy_paths() {
    local src="$1" dst="$2"
    local dir name legacy newpath old ff nlink unsafe
    local -A used=()
    local k

    for k in "${!CHAP_DST[@]}"; do
        local u="${CHAP_DST["$k"]}"
        [ -n "$u" ] && used["$u"]=1
    done

    while IFS= read -r dir; do
        name=$(basename "$dir")
        newpath="${CHAP_DST["$name"]:-}"
        [ -z "$newpath" ] && continue          # superseded chapter, nothing to clean
        legacy="$(sanitize_dir_name "$name")"
        [ -z "$legacy" ] && continue
        [ "$legacy" = "$newpath" ] && continue  # naming unchanged for this chapter
        [ -n "${used["$legacy"]:-}" ] && continue  # another chapter uses that path
        old="$dst/$legacy"
        [ -d "$old" ] || continue

        unsafe=0
        while IFS= read -r -d '' ff; do
            nlink=$(stat -c %h "$ff" 2>/dev/null || echo 1)
            if [ "$nlink" -lt 2 ]; then
                unsafe=1
                break
            fi
        done < <(find "$old" -type f -print0 2>/dev/null)
        [ "$unsafe" -eq 1 ] && continue

        log_info "  ↻ Removing replaced folder: $legacy"
        rm -rf -- "$old"
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# Map a source-relative directory path to its destination-relative path.
# The first path component is the chapter folder and comes from the map; any
# deeper components are sanitized individually.
map_rel_dir() {
    local rel_dir="$1"
    if [ -z "$rel_dir" ]; then
        echo ""
        return
    fi
    local first="${rel_dir%%/*}"
    local mapped=""
    if [ -n "$first" ]; then
        mapped="${CHAP_DST["$first"]:-}"
    fi
    if [ -z "$mapped" ]; then
        mapped="$(sanitize_dir_name "$first")"
    fi
    if [ "$rel_dir" = "$first" ]; then
        echo "$mapped"
    else
        echo "$mapped/$(sanitize_path "${rel_dir#*/}")"
    fi
}

# Newest mtime among the files under a directory, at sub-second precision.
# Whole-second granularity is not enough here: a chapter that is re-downloaded
# within the same second as the previous failure must still register as changed.
newest_mtime() {
    find "$1" -type f -printf '%T@\n' 2>/dev/null \
        | awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { printf "%.6f", m }'
}

# Marker file recording that a chapter failed validation, holding the newest
# source mtime at the time it failed. Used so the error is reported ONCE: a
# chapter that is still broken and has not changed since is skipped silently
# on later scans until the user re-downloads it.
failed_flag_path() {
    printf '%s/%s.flag' "$FAILED_DIR" "$(printf '%s' "$1" | tr '/ ' '__')"
}

# === Corrupt / empty file detection ===
# Returns 0 when every file in the chapter looks sound, 1 otherwise.
# Reports ONE line per chapter (plus up to three example filenames) rather
# than a line per bad file — a broken chapter can have 80+ bad files and the
# per-file spam buries the rest of the log.
validate_chapter_files() {
    local dir="$1" book="$2" chapter="$3"

    [ "${VALIDATE_FILES:-1}" -eq 1 ] || return 0
    [ -d "$dir" ] || return 0

    local f size hex riff bad_count=0 unreadable=0
    local -a bad=()

    while IFS= read -r -d '' f; do
        size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        if [ "$size" -eq 0 ]; then
            bad+=("$f")
            bad_count=$((bad_count + 1))
            continue
        fi
        case "$f" in
            *.webp|*.WEBP)
                # od -N12 gives 12 bytes = 24 hex chars. Layout:
                #   bytes 0-3  "RIFF"   -> hex 0-7
                #   bytes 4-7  size    -> hex 8-15
                #   bytes 8-11 "WEBP"  -> hex 16-23
                hex=$(od -An -tx1 -N12 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ -z "$hex" ]; then
                    # The file could not be READ at all (I/O error, stale NFS
                    # handle, dead disk). That is a storage problem, not a
                    # bad download — say so, because the fix is completely
                    # different from "re-download this chapter".
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                    unreadable=$((unreadable + 1))
                elif [ "${hex:0:8}" != "52494646" ] || [ "${hex:16:8}" != "57454250" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                else
                    # The RIFF size field is LITTLE-endian, so the four bytes
                    # have to be reversed before reading them as a number.
                    # (bytes 4-7 = 04 00 00 00 means 4, not 67108864)
                    riff=0
                    if [ "${#hex}" -ge 16 ]; then
                        riff=$((16#${hex:14:2}${hex:12:2}${hex:10:2}${hex:8:2})) 2>/dev/null || riff=0
                    fi
                    if [ $((riff + 8)) -ne "$size" ]; then
                        bad+=("$f")
                        bad_count=$((bad_count + 1))
                    fi
                fi
                ;;
            *.avif|*.AVIF)
                hex=$(od -An -tx1 -N12 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:8:8}" != "66747970" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
            *.jpg|*.JPG|*.jpeg|*.JPEG)
                hex=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:0:4}" != "ffd8" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
            *.png|*.PNG)
                hex=$(od -An -tx1 -N8 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:0:16}" != "89504e470d0a1a0a" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
            *.gif|*.GIF)
                hex=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:0:6}" != "474946" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
            *.pdf|*.PDF)
                hex=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:0:8}" != "25504446" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
            *.cbz|*.CBZ|*.cbr|*.CBR|*.zip|*.ZIP|*.epub|*.EPUB)
                hex=$(od -An -tx1 -N2 "$f" 2>/dev/null | tr -d ' \n' || echo "")
                if [ "${hex:0:4}" != "504b" ]; then
                    bad+=("$f")
                    bad_count=$((bad_count + 1))
                fi
                ;;
        esac
    done < <(find "$dir" -type f -print0 2>/dev/null)

    if [ "$bad_count" -gt 0 ]; then
        if [ "$unreadable" -gt 0 ]; then
            log_error "Unreadable chapter — not linked: $book / $chapter ($unreadable of $bad_count file(s) could not be READ — storage problem, not a bad download)"
        else
            log_error "Corrupt chapter — not linked: $book / $chapter ($bad_count bad file(s))"
        fi
        local ex="" b
        for b in "${bad[@]:0:3}"; do
            ex="$ex, $(basename "$b")"
        done
        log_error "    first bad files:${ex#, }"
        return 1
    fi
    return 0
}

# Sanitize a path's directory portion (each /-separated component).
sanitize_path() {
    local p="$1"
    local result=""
    local IFS='/'
    local component
    for component in $p; do
        if [ -n "$result" ]; then
            result="$result/"
        fi
        result="$result$(sanitize_dir_name "$component")"
    done
    echo "$result"
}

# === Logging helpers ===
log_info()  { echo "[$(date -u +%H:%M:%SZ)] ℹ️  $*"; }
log_warn()  { echo "[$(date -u +%H:%M:%SZ)] ⚠️  $*"; }
log_error() { echo "[$(date -u +%H:%M:%SZ)] ❌ $*" >&2; }

# === Validation ===
if [ ! -d "$SRC_ROOT" ]; then
    log_error "SRC_ROOT does not exist: $SRC_ROOT"
    exit 1
fi
if [ ! -d "$DST_ROOT" ]; then
    log_error "DST_ROOT does not exist: $DST_ROOT"
    exit 1
fi

# Ensure DST has type subdirs
for type in "${TYPES[@]}"; do
    mkdir -p "$DST_ROOT/$type"
done

# === Startup banner ===
log_info "📂 Booklinkarr watching $SRC_ROOT → $DST_ROOT"
log_info "   Types: ${TYPES[*]}"
log_info "   Rescan interval: ${SCAN_INTERVAL}s"
if [ "${PURGE_ORPHANS:-0}" -eq 1 ]; then
    log_info "   Purge orphans: ENABLED (inode-based, on each rescan)"
else
    log_info "   Purge orphans: index built + cached each scan, but no auto-delete (set PURGE_ORPHANS=1)"
fi
log_info "   Inode cache: ${CACHE_DIR:-/var/lib/booklinkarr} (bind-mount to persist across container recreations)"
log_info "   Running as: $(id -un 2>/dev/null || echo 'unknown') (uid=$(id -u 2>/dev/null || echo '?'))"

# === File operations ===

# Count files in a directory recursively. Returns 0 if dir is empty or missing.
count_files() {
    find "$1" -type f 2>/dev/null | wc -l
}

# Hardlink a single file. Logs warning on failure. Returns 0 on success.
# Future cross-device safety net (deferred — user's data is single-disk):
#   # if cp "$src" "$dst" 2>/dev/null; then
#   #     log_warn "Copied (cross-device): $src"
#   #     return 0
#   # fi
hardlink_file() {
    local src="$1" dst="$2"
    if ln "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    log_warn "Hardlink failed: $src"
    return 1
}

# Sync a single book series from src to dst.
# - dst is the SANITIZED dest path (caller has already stripped digits from book name)
# - Per-file rel path is also sanitized (chapter folder names get the "Chapter N" form)
# - Skips per-file if dest already exists
# - Logs progress every 500 missing files during long syncs
# - Logs series summary at the end (skipped / synced / partial)
sync_series() {
    local src="$1" dst="$2"

    [ ! -d "$src" ] && return 0

    # === FAST PATH: skip per-file iteration if src hasn't changed since last sync ===
    # Cache file mtime marks the last sync time. If no source file is newer than
    # that, nothing changed since last sync and we can skip the per-file loop.
    # What this catches (slow path): new chapter folders, in-chapter file mods.
    # What it misses (cache hit): src deletions → caught by PURGE_ORPHANS instead.
    local cache_file="$STAT_CACHE_DIR/$(printf '%s' "$dst" | tr '/' '_').cache"
    if [ -f "$cache_file" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
        if [ "$cache_age" -le "$STAT_CACHE_MAX_AGE" ] && \
           [ -z "$(find "$src" -newer "$cache_file" -type f -print -quit 2>/dev/null)" ]; then
            if should_log_skip "$dst"; then
                log_info "✓ Cache hit: $dst"
            fi
            return 0
        fi
    fi

    mkdir -p "$dst"

    # Stamp the cache with the time this scan started, not the time it ends and
    # not the newest source file's mtime. A file that arrives WHILE this scan
    # is running then still has a newer mtime than the cache, so the next scan
    # picks it up instead of skipping it forever.
    local scan_start
    scan_start=$(date +%s)

    # Build the per-book chapter map: decides each chapter's destination path,
    # handles season renumbering, side stories and chapter replacement.
    build_chapter_map "$src"

    # A book whose files sit directly in the book directory (no chapter
    # subfolders) would never be validated, because validation runs per chapter.
    # Treat the whole book as one unit in that case.
    local book_has_chapters=0 d
    while IFS= read -r d; do
        book_has_chapters=1
        break
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if [ "$book_has_chapters" -eq 0 ]; then
        if ! validate_chapter_files "$src" "$(basename "$dst")" "(whole book)"; then
            log_error "  Skipping the entire book — it was not linked"
            return 0
        fi
    fi

    # Remove destination folders that the current naming scheme replaces.
    cleanup_legacy_paths "$src" "$dst"

    mapfile -t src_files < <(find "$src" -type f 2>/dev/null)

    local total=${#src_files[@]}
    local missing=0 linked=0 failed=0
    local progress_interval=500
    local last_progress=0
    local syncing_logged=0
    local -A seen_chapter=()
    local -A skip_chapter=()

    for src_file in "${src_files[@]}"; do
        # Quote "$src" so it is matched LITERALLY. Without the quotes bash
        # treats the directory name as a glob pattern, and a name containing
        # brackets (e.g. "Naruto Novels [VIZ Media] [LuCaZ]") becomes a
        # character class — the prefix then fails to match, rel keeps the
        # whole absolute path, and the chapter name ends up empty.
        local rel="${src_file#"$src"/}"

        # Split into dir portion (sanitize) and file portion (keep as-is).
        # The chapter folder part comes from the chapter map so that seasons and
        # side stories land where they should. Filenames are left alone so
        # "001.webp" stays as "001.webp" (no extension loss / no collisions).
        local rel_dir rel_file
        rel_dir=$(dirname "$rel")
        rel_file=$(basename "$rel")

        # The first path component is the chapter folder.
        local chap=""
        if [ "$rel_dir" != "." ]; then
            chap="${rel_dir%%/*}"
        fi

        # Validate and prepare each chapter once, before linking its files.
        if [ -n "$chap" ] && [ -z "${seen_chapter["$chap"]:-}" ]; then
            seen_chapter["$chap"]=1
            if [ -n "${CHAP_SKIP["$chap"]:-}" ]; then
                continue
            fi

            # === PER-CHAPTER FAST PATH ===
            # If the destination already holds exactly as many files as the
            # source chapter, and no source file is newer than the destination
            # directory, the per-file loop would find nothing to do. A find+wc
            # costs two C-speed passes instead of a stat() per file — on a book
            # with 20k pages that is the difference between seconds and minutes.
            # A renamed chapter does not match here (its destination path does
            # not exist yet), so renames still take the slow path.
            local chap_dst="$dst/${CHAP_DST["$chap"]:-}"
            if [ -n "$chap_dst" ] && [ -d "$chap_dst" ]; then
                local scount dcount
                scount=$(find "$src/$chap" -type f 2>/dev/null | wc -l)
                dcount=$(find "$chap_dst" -type f 2>/dev/null | wc -l)
                if [ "$scount" -gt 0 ] && [ "$scount" -eq "$dcount" ] && \
                   [ -z "$(find "$src/$chap" -newer "$chap_dst" -type f -print -quit 2>/dev/null)" ]; then
                    skip_chapter["$chap"]=1
                    continue
                fi
            fi

            # === KNOWN FAILURE: skip silently if nothing changed ===
            # A chapter that already failed validation is not linked, so it has
            # no destination folder and the fast path never applies to it. Track
            # the failure with a marker file so the error is reported once and
            # the chapter is re-checked only when its source actually changes.
            local flag known_m cur_m
            flag="$(failed_flag_path "$chap")"
            if [ -f "$flag" ]; then
                known_m=$(cat "$flag" 2>/dev/null)
                cur_m=$(newest_mtime "$src/$chap")
                if [ "$known_m" = "$cur_m" ]; then
                    skip_chapter["$chap"]=1
                    continue
                fi
            fi

            if ! validate_chapter_files "$src/$chap" "$(basename "$dst")" "${CHAP_DST["$chap"]:-${chap}}"; then
                CHAP_SKIP["$chap"]=1
                mkdir -p "$FAILED_DIR"
                newest_mtime "$src/$chap" > "$flag" 2>/dev/null
                continue
            fi
            # Replacement detection: if the destination's first file points at a
            # different inode than the source's, this chapter was replaced with
            # another scanlator's version. Wipe it so the new content is linked
            # instead of the stale hardlinks (which would otherwise sit there
            # until PURGE_ORPHANS noticed, one rescan later).
            local rep_src rep_rel rep_dir rep_dst
            rep_src=$(find "$src/$chap" -type f -print -quit 2>/dev/null)
            if [ -n "$rep_src" ]; then
                rep_rel="${rep_src#"$src"/}"
                rep_dir=$(dirname "$rep_rel")
                rep_dst="$dst"
                if [ "$rep_dir" != "." ]; then
                    rep_dst="$dst/$(map_rel_dir "$rep_dir")"
                fi
                rep_dst="$rep_dst/$(basename "$rep_src")"
                if [ -e "$rep_dst" ]; then
                    local src_inode dst_inode
                    src_inode=$(stat -c %i "$rep_src" 2>/dev/null || echo 0)
                    dst_inode=$(stat -c %i "$rep_dst" 2>/dev/null || echo 0)
                    if [ "$src_inode" != "$dst_inode" ]; then
                        log_info "  ↻ Replacing chapter: $chap"
                        local wipe_path="${CHAP_DST["$chap"]:-}"
                        if [ -n "$wipe_path" ] && [ "${wipe_path#/}" != "$wipe_path" ]; then
                            rm -rf "$dst/$wipe_path"
                        fi
                    fi
                fi
            fi
        fi
        if [ -n "$chap" ] && [ -n "${CHAP_SKIP["$chap"]:-}" ]; then
            continue
        fi
        if [ -n "$chap" ] && [ -n "${skip_chapter["$chap"]:-}" ]; then
            continue
        fi

        local sanitized_dir=""
        if [ "$rel_dir" != "." ]; then
            sanitized_dir=$(map_rel_dir "$rel_dir")
        fi

        local dst_file
        if [ -n "$sanitized_dir" ]; then
            dst_file="$dst/$sanitized_dir/$rel_file"
        else
            dst_file="$dst/$rel_file"
        fi

        if [ -e "$dst_file" ]; then
            continue
        fi
        if [ "$syncing_logged" -eq 0 ]; then
            log_info "🔄 Syncing: $dst — $total files total"
            syncing_logged=1
        fi
        mkdir -p "$(dirname "$dst_file")"
        missing=$((missing + 1))
        if hardlink_file "$src_file" "$dst_file"; then
            linked=$((linked + 1))
        else
            failed=$((failed + 1))
        fi
        if [ $((missing - last_progress)) -ge "$progress_interval" ]; then
            log_info "  ↳ Progress: $missing/$total files processed ($linked linked, $failed failed)"
            last_progress=$missing
        fi
    done

    if [ "$total" -eq 0 ]; then
        log_warn "⚠️  Source has no files (yet?): $src → $dst"
    elif [ "$missing" -eq 0 ]; then
        if should_log_skip "$dst"; then
            log_info "✓ All $total files already present, skipping: $dst"
        fi
    elif [ "$failed" -eq 0 ]; then
        log_info "🔗 Synced: $dst — linked=$linked (total=$total)"
    else
        log_warn "⚠️  Partial sync: $dst — linked=$linked failed=$failed (total=$total)"
    fi

    # Update the scan cache, stamped with this scan's start time (see above).
    mkdir -p "$STAT_CACHE_DIR"
    touch -d "@$scan_start" "$cache_file" 2>/dev/null || touch "$cache_file"
    return 0
}

# === Scan a single type dir for book folders and sync each ===
scan_type() {
    local type="$1"
    local src_type_dir="$SRC_ROOT/$type"
    [ -d "$src_type_dir" ] || return 0  # Explicit 0 so set -e doesn't kill the parent

    mapfile -t book_dirs < <(find "$src_type_dir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
    for book_dir in "${book_dirs[@]}"; do
        local book_name
        book_name=$(basename "$book_dir")
        # Sanitize the BOOK folder name (strips digits to avoid Kavita's parser
        # bug). Source keeps original (Suwayomi is the source of truth); dest is
        # sanitized. sanitize_book_name returns "unknown_series" for empty input.
        local dest_book_name
        dest_book_name=$(sanitize_book_name "$book_name")
        local dst_book="$DST_ROOT/$type/$dest_book_name"
        sync_series "$book_dir" "$dst_book"
    done
    return 0  # Explicit success
}

# === Log deduplication for smart-skip messages ===
# Avoid Dozzle flooding when inotify fires multiple times for the same book
# in rapid succession (e.g., during torrent extraction of many files).
# Same dst path within SKIP_DEDUP_WINDOW seconds only logs once.

declare -A last_skip_log
SKIP_DEDUP_WINDOW="${SKIP_DEDUP_WINDOW:-10}"  # seconds

should_log_skip() {
    local dst="$1"
    local now
    now=$(date +%s)
    local last="${last_skip_log[$dst]:-0}"
    local diff=$((now - last))
    if [ "$diff" -ge "$SKIP_DEDUP_WINDOW" ]; then
        last_skip_log[$dst]=$now
        return 0  # log this one
    fi
    return 1  # suppress (logged too recently)
}

# Inotify debounce per book folder. When a torrent/zip is being extracted, inotify may
# fire dozens of times in quick succession (one per file write). We skip subsequent
# triggers for the same book within INOTIFY_DEBOUNCE seconds — the periodic rescan will
# catch any work the debounce missed. This is the key fix for the inotify "wonkiness"
# the user saw during active downloads.
declare -A last_book_sync
INOTIFY_DEBOUNCE="${INOTIFY_DEBOUNCE:-30}"  # seconds

should_sync_book() {
    local book_dir="$1"
    local now
    now=$(date +%s)
    local last="${last_book_sync[$book_dir]:-0}"
    local since=$((now - last))
    if [ "$since" -ge "$INOTIFY_DEBOUNCE" ]; then
        last_book_sync[$book_dir]=$now
        return 0  # yes, sync this one
    fi
    return 1  # too soon, skip (will be caught by next periodic rescan)
}

# === Scan all types (initial scan + periodic rescan reuse this) ===
# Tracks whether the first scan since startup has completed. Used by purge_orphans
# to force a slow path on the initial scan (so pre-existing orphans are caught) and
# use the fast path on subsequent rescans.
INITIAL_SCAN_DONE=false

scan_all_types() {
    for type in "${TYPES[@]}"; do
        scan_type "$type"
    done
    purge_orphans
    INITIAL_SCAN_DONE=true
    log_info "✅ Scan and sync complete. Next rescan in ~${SCAN_INTERVAL}s ($(($SCAN_INTERVAL / 60)) min)"
    return 0
}

# === Purge orphans + inode cache management ===
# Behavior:
#   - ALWAYS builds + caches the source inode set on every scan (saves drive wear + speeds up
#     future runs, even if PURGE_ORPHANS=0).
#   - When PURGE_ORPHANS=1, also deletes dest files whose inodes no longer match any source
#     file (e.g., after migrating Suwayomi from one source to another).
#
# Algorithm:
#   Pass 1: Build current source inode set (in-memory hash).
#   Pass 2 (if cache available): Compare with cached set. For each inode that disappeared,
#     find dest files with that inode and delete. (O(M × log M) — typically very fast since
#     few inodes disappear per scan.)
#   Pass 2 (if no cache or expired): Walk entire dest tree and check each inode against the
#     current set. (O(N × log M) where N=dest count.)
#
# Cache:
#   - Stored at $CACHE_DIR/inode_cache (default /var/lib/booklinkarr)
#   - Bind-mount /var/lib/booklinkarr to a host dir (e.g. ./appdata/booklinkarr) so it
#     survives container recreations and image updates.
#   - Cache is considered stale if older than PURGE_CACHE_MAX_AGE seconds (default 86400 = 24h).
#
# Cost: For 50k source files on virtiofs, indexing takes ~3-5 min once. Subsequent scans
#   use the cache diff and finish in seconds.
purge_orphans() {
    local start_epoch
    start_epoch=$(date +%s)

    local cache_dir="${CACHE_DIR:-/var/lib/booklinkarr}"
    mkdir -p "$cache_dir"
    local cache_file="$cache_dir/inode_cache"
    local cache_max_age="${PURGE_CACHE_MAX_AGE:-86400}"
    local use_cache=false

    # Load previous cache if it exists and is fresh enough
    declare -A prev_inodes
    if [ -f "$cache_file" ]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
        if [ "$cache_age" -le "$cache_max_age" ]; then
            while IFS= read -r inode; do
                [ -n "$inode" ] && prev_inodes[$inode]=1
            done < "$cache_file"
            log_info "  Loaded ${#prev_inodes[@]} inodes from cache ($cache_age sec old)"
            use_cache=true
        else
            log_info "  Cache is $cache_age sec old (> $cache_max_age sec), rebuilding from scratch"
        fi
    else
        log_info "  No cache file found at $cache_file — building index now (this takes a few minutes)"
    fi

    # Build current source inode set. Skip rebuild if cache is fresh AND no source files
    # have been modified since the cache was built (typical case: nothing changed).
    declare -A current_inodes
    local src_count=0
    local needs_index_rebuild=true

    if [ "$use_cache" = "true" ]; then
        # Quick check: any source file newer than the cache file?
        if find "$SRC_ROOT" -newer "$cache_file" -type f -print -quit 2>/dev/null | grep -q .; then
            log_info "  Source files modified since cache, doing full rebuild"
        else
            log_info "  No source files modified since cache build — skipping rebuild, reusing cache"
            # Reuse cache as the current set (no source walk needed)
            for k in "${!prev_inodes[@]}"; do
                current_inodes[$k]=1
            done
            needs_index_rebuild=false
        fi
    fi

    if [ "$needs_index_rebuild" = "true" ]; then
        while IFS= read -r -d '' src_file; do
            local inode
            inode=$(stat -c %i "$src_file" 2>/dev/null) || continue
            current_inodes[$inode]=1
            src_count=$((src_count + 1))
            if [ $((src_count % 5000)) -eq 0 ]; then
                log_info "  Indexed $src_count source inodes..."
            fi
        done < <(find "$SRC_ROOT" -type f -print0 2>/dev/null)
        log_info "  Indexed $src_count source files (inodes unique: ${#current_inodes[@]})"
    else
        src_count=${#current_inodes[@]}
        log_info "  Reused ${#current_inodes[@]} inodes from cache (no source walk)"
    fi

    # Always save current set for next scan (only if we rebuilt; otherwise cache is unchanged)
    if [ "$needs_index_rebuild" = "true" ]; then
        : > "$cache_file"
        for inode in "${!current_inodes[@]}"; do
            echo "$inode" >> "$cache_file"
        done
        log_info "  Saved ${#current_inodes[@]} inodes to cache ($cache_file, $(stat -c %s "$cache_file") bytes)"
    fi

    # If PURGE_ORPHANS=0, skip the orphan-detection/delete step
    if [ "${PURGE_ORPHANS:-0}" -ne 1 ]; then
        log_info "  PURGE_ORPHANS=0 — index built + cached, but no orphan deletion"
        unset prev_inodes current_inodes
        return 0
    fi

    log_warn "🧹 PURGE_ORPHANS=1 — scanning for orphaned files (inode-based)"

    local purged=0
    local scanned=0

    # Decide fast vs slow path:
    #   - First scan since startup: ALWAYS slow path (catches pre-existing orphans that the
    #     cache-diff fast path can't see, since the cache only knows about inodes that existed
    #     at the time of the last cache build).
    #   - Subsequent scans: use cache diff (fast) when cache is fresh; slow path as fallback
    #     when cache is missing or expired.
    #   - User can force a slow path at any time by `docker restart booklinkarr`.
    local use_slow_path=false
    if [ "$INITIAL_SCAN_DONE" = "false" ]; then
        use_slow_path=true
        log_info "  First scan since startup, using slow path (catches pre-existing orphans)"
    fi

    if [ "$use_cache" = "true" ] && [ "$use_slow_path" = "false" ]; then
        # FAST PATH: only check inodes that DISAPPEARED since last scan
        log_info "  Fast path: checking only inodes that vanished since last scan"
        local vanished=0
        for inode in "${!prev_inodes[@]}"; do
            if [ -z "${current_inodes[$inode]:-}" ]; then
                vanished=$((vanished + 1))
                while IFS= read -r -d '' orphan; do
                    log_info "  Purging orphan (inode $inode): $orphan"
                    rm -f "$orphan"
                    purged=$((purged + 1))
                done < <(find "$DST_ROOT" -type f -inum "$inode" -print0 2>/dev/null)
            fi
        done
        log_info "  $vanished inodes vanished since last scan, $purged dest file(s) purged"
    else
        # SLOW PATH: full scan of dest tree
        if [ "$use_slow_path" = "true" ]; then
            log_info "  Slow path: full dest tree scan (initial scan since startup)"
            log_info "    → Checks ALL dest inodes to catch orphans the fast-path cache-diff can't see"
            log_info "    → Used automatically on first scan; fast path takes over for subsequent rescans"
            log_info "    → To re-trigger slow path manually: 'docker restart booklinkarr'"
        else
            log_info "  Slow path: full dest tree scan (no cache or cache expired)"
        fi
        for type in "${TYPES[@]}"; do
            local bk_base="$DST_ROOT/$type"
            [ -d "$bk_base" ] || continue

            while IFS= read -r -d '' dst_file; do
                scanned=$((scanned + 1))
                local inode
                inode=$(stat -c %i "$dst_file" 2>/dev/null) || continue
                if [ -z "${current_inodes[$inode]:-}" ]; then
                    log_info "  Purging orphan (inode $inode): $dst_file"
                    rm -f "$dst_file"
                    purged=$((purged + 1))
                fi
                if [ $((scanned % 1000)) -eq 0 ]; then
                    log_info "  Scanned $scanned dest files, purged $purged so far..."
                fi
            done < <(find "$bk_base" -type f -print0 2>/dev/null)
        done
    fi

    local elapsed=$(( $(date +%s) - start_epoch ))
    log_info "✅ Purge complete: $purged orphan(s) deleted (took $elapsed sec)"

    # Clean up empty directories left behind by the purge (or from any prior run).
    # -depth + -empty ensures we only target directories with no files; deepest first so
    # a chain of empty parents gets removed. -mindepth 3 protects the top-level /books/
    # and /books/<type>/ directories.
    log_info "  Removing empty directories under $DST_ROOT (depth >= 3)..."
    local dirs_removed=0
    while IFS= read -r -d '' dir; do
        # rmdir fails on non-empty (safe); succeeds on empty
        if rmdir "$dir" 2>/dev/null; then
            dirs_removed=$((dirs_removed + 1))
        fi
    done < <(find "$DST_ROOT" -mindepth 3 -depth -type d -empty -print0 2>/dev/null)
    log_info "  Removed $dirs_removed empty director(ies)"

    # Free memory
    unset prev_inodes current_inodes
}

# === Inotify watcher ===
# For each type dir, spawn a background process that watches for create/moved_to events.
# On any event, walks up the path to find the book folder (depth 2 relative to $SRC_ROOT)
# and syncs it. Depth = 2 corresponds to the BOOK folder structure: <type>/<site>/<book>/.
start_watch() {
    local src_dir="$1" type_label="$2"
    (
        inotifywait -m -r -e create,moved_to --format '%w%f' "$src_dir" 2>/dev/null |
        while read -r path; do
            local book_dir=""
            local candidate="$path"
            while [ "$candidate" != "$SRC_ROOT" ]; do
                local rel="${candidate#$SRC_ROOT/}"
                local depth
                depth=$(echo "$rel" | tr -cd '/' | wc -c)
                if [ "$depth" -eq 2 ]; then
                    book_dir="$candidate"
                    break
                fi
                local new_candidate
                new_candidate=$(dirname "$candidate")
                # Safety: stop if dirname doesn't make progress (reached filesystem root)
                [ "$new_candidate" = "$candidate" ] && break
                candidate="$new_candidate"
            done
            if [ -n "$book_dir" ]; then
                # Debounce: skip if we just synced this book within INOTIFY_DEBOUNCE seconds.
                # The periodic rescan (every SCAN_INTERVAL) will catch anything skipped.
                if ! should_sync_book "$book_dir"; then
                    continue
                fi
                local book_name
                book_name=$(basename "$book_dir")
                # Sanitize BOOK name (digits stripped) so inotify-triggered syncs
                # write to the same dest path as the periodic rescan. Without this,
                # "The Archmage Returns After 4000 Years" would be created as a
                # new unsanitized folder, orphaning the existing "After Years" one.
                local dest_book_name
                dest_book_name=$(sanitize_book_name "$book_name")
                local dst_book="$DST_ROOT/$type_label/$dest_book_name"
                sync_series "$book_dir" "$dst_book"
            fi
        done
    ) &
}

# === Periodic rescan loop ===
start_rescan() {
    while true; do
        sleep "$SCAN_INTERVAL"
        log_info "🔁 Periodic rescan (every ${SCAN_INTERVAL}s)"
        scan_all_types
    done
}

# === Main flow ===
log_info "🚀 Running initial scan..."
scan_all_types

# Spawn watchers
for type in "${TYPES[@]}"; do
    src_type_dir="$SRC_ROOT/$type"
    [ -d "$src_type_dir" ] || continue
    start_watch "$src_type_dir" "$type"
done

# Spawn rescan loop in background
start_rescan &

log_info "✅ Booklinkarr running. Press Ctrl+C to stop."
wait

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

# === Path sanitization (Kavita parser compat + chapter rename) ===
# Two goals:
#   1) Avoid Kavita's parser bug for series with digits in the title. The parser
#      extracts digits and treats them as chapter numbers — "The Archmage Returns
#      After 4000 Years" gets parsed as chapter 4000 with 3999 phantom predecessors.
#      Strips digits from the BOOK folder name to dodge this (the book folder
#      rename doesn't affect chapter identity).
#   2) Strip the scanlator/series prefix from CHAPTER folder names while keeping
#      the chapter TYPE identifier (Chapter, Episode, Blank, Ep.) and number.
#      Example: "Atsumaru (EN)_Devil Butler_Episode 5" -> "Episode 5"
#      This keeps each chapter uniquely addressable in dst (without this, all
#      301 episodes sanitized to the same string and merged into one folder).
# Filenames are NOT sanitized (file extensions and numeric ordering preserved).
# Strip scanlator/series prefix while preserving the chapter TYPE identifier
# and normalizing abbreviations. Recognized types (full → dst form):
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
# identifier is found — the v0.6 digit-strip fallback was the merge bug.
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
    # (The old v0.6 digit-strip fallback merged all chapters of a series into
    # one dst folder, so we never strip digits here.)
    echo "$name" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
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
    mkdir -p "$dst"

    mapfile -t src_files < <(find "$src" -type f 2>/dev/null)

    local total=${#src_files[@]}
    local missing=0 linked=0 failed=0
    local progress_interval=500
    local last_progress=0
    local syncing_logged=0

    for src_file in "${src_files[@]}"; do
        local rel="${src_file#$src/}"

        # Split into dir portion (sanitize) and file portion (keep as-is).
        # sanitize_path strips digits from directory names but leaves filenames alone
        # so "001.webp" stays as "001.webp" (no extension loss / no collisions).
        local rel_dir rel_file
        rel_dir=$(dirname "$rel")
        rel_file=$(basename "$rel")

        local sanitized_dir=""
        if [ "$rel_dir" != "." ]; then
            sanitized_dir=$(sanitize_path "$rel_dir")
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
        # Sanitize the book folder name so dest paths don't trigger Kavita's parser.
        # Source keeps original (Suwayomi is the source of truth), dest is sanitized.
        local dest_book_name
        dest_book_name=$(sanitize_dir_name "$book_name")
        if [ -z "$dest_book_name" ]; then
            dest_book_name="unknown_series"
        fi
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
                # Sanitize book name (same logic as scan_type) so inotify-triggered syncs
                # write to the same dest path as the periodic rescan.
                local dest_book_name
                dest_book_name=$(sanitize_dir_name "$book_name")
                if [ -z "$dest_book_name" ]; then
                    dest_book_name="unknown_series"
                fi
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

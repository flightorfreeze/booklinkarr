# Booklinkarr Season-Aware Chapter Naming — Design Spec

**Date:** 2026-10-30
**Repo:** `C:\Users\carte\Desktop\booklinkrr\booklinkrr`
**Image:** `ghcr.io/flightorfreeze/booklinkarr:latest`
**Supersedes:** the v0.7 `sanitize_dir_name` behaviour described in
[[booklinkarr-v0.7-status]]

## Problem

Jungle Juice (webtoon) has 226 chapters whose source folders encode a season
suffix: `Atsumaru (EN)_Jungle Juice_Alpha_Episode 12 S2`.

Kavita parses `Episode 12 S2` as *chapter number 12* and groups it into a
volume for season 2. It does **not** make the number globally unique — S1's
`Episode 12`, S2's `Episode 12` and S3's `Episode 12` all become chapter 12 in
different volumes.

Mihon's Kavita extension flattens volumes and sorts by chapter number, so the
seasonal structure collapses into an interleaved pile:

```
Episode 01, Episode 01, Episode 01,   ← S1E1, S2E1, S3E1
Episode 02, Episode 02, Episode 02,   ← S1E2, S2E2, S3E2
...
```

Consequences the user cares about:

- Cannot scroll to "the next chapter" — the list order is wrong.
- Cannot tell which "chapter 37" is the one to resume from; picking the wrong
  one risks spoilers.

A second, independent defect: `sanitize_dir_name` only recognises a fixed set
of chapter type words (Chapter / Episode / Blank / Volume / Vol / Ep / Ch).
Anything else falls through **unchanged**, so
`Atsumaru (EN)_Jungle Juice_Alpha_Spin-off 1` reached the destination with its
`(EN)` scanlator prefix intact. That violates the "never create an unsanitized
dst directory" invariant, and it produced a delete/recreate loop with the
`(EN)`-based cleanup script.

## Goals

1. Every chapter in a book gets a **globally unique, monotonically increasing**
   number, so Kavita reports unique numbers and Mihon sorts correctly.
2. Season structure is preserved in the destination tree.
3. The chapter **type word is taken from the source folder** and never
   normalised — `Episode` stays `Episode`, `Chapter` stays `Chapter`,
   `Spin-off` stays `Spin-off`.
4. Decimal interstitials (`83.5`, `77.7`) keep their decimal value and their
   position between the surrounding chapters.
5. Side stories land **after** the main story.
6. Books with **no season markers are not renumbered at all** — no churn, no
   lost reading progress.
7. Replacing a chapter with a better scanlator's version replaces it in place.

## Non-goals

- Changing Suwayomi (not in the reading path; Mihon reads from Kavita).
- Inferring a chapter type for folders that have none.
- Renaming chapters inside the Kavita UI (the user explicitly will not do this).

## Background facts (verified against the live system)

| Fact | Evidence |
|---|---|
| Mihon reads from **Kavita** via the Kavita extension, not from Suwayomi | User's Mihon "Browse → Sources" shows `Kavita (Home Server)`; Suwayomi is installed but unconfigured |
| Mihon sorts by Kavita's `Chapter.Number` | Jungle Juice shows `Episode 01` three times = S1/S2/S3 each numbering that episode 1 |
| Kavita extracts the trailing number from any chapter folder name | `Chapter 321` → Kavita `Number=321` (The Devil Butler); `Spin-off 1` → `Number=1` |
| Kavita puts root-level chapters in a special loose volume (`-100000`) | Both Jungle Juice and The Devil Butler use it |
| Kavita assigns volumes from the season suffix | Jungle Juice has volumes `1`, `2`, `3` + loose `-100000` |
| Source folder names are `<scanlator>_<chapterName>` | Suwayomi jar patch `getChapterDir()` in `MODIFICATIONS.md` |
| Only Jungle Juice has season markers on disk | `find` across all books |
| The Devil Butler mixes `Episode N` and `Chapter N` families with non-overlapping number ranges (1–99 and 300–564), 549 chapters total | Kavita DB, series id 301 |

## Design

### 1. Two sanitizers, three responsibilities

The v0.7 split into `sanitize_book_name` / `sanitize_dir_name` was correct and
stays. This spec adds a third function and changes one.

```
sanitize_book_name(name)     # BOOK folder: strip digits (Kavita parser compat)
sanitize_dir_name(name)      # CHAPTER folder: preserve type word + number
sanitize_chapter_dir(name)   # NEW: chapter folder within a book — season-aware
```

`sanitize_dir_name` keeps its current behaviour (Chapter / Episode / Blank /
Volume / Vol / Ep / Ch → `<Type> <rest>`), used for the *legacy* path
computation in §6 and as the fallback for `sanitize_chapter_dir`.

### 2. Parsing a chapter folder name

A chapter folder name is parsed into:

| Field | Source | Notes |
|---|---|---|
| `type` | First recognised type keyword | `Chapter`, `Episode`, `Blank`, `Volume`, `Vol`, `Ep`, `Ch`, `Spin-off`, `Side Story`, `Bonus`, `Extra`, `Special`, `Omake` |
| `season` | Trailing `S<n>`, `S <n>`, `Season <n>`, `Season<n>`, `Se <n>` | Absent if no marker |
| `number` | The numeric token associated with `type` | May be decimal (`83.5`). Absent if the name has no number. |
| `residual` | The text left over after removing the type keyword and number | Used for canonical preference (§4). The scanlator/series prefix is part of this and cancels out when comparing two chapters. |
| `is_side_story` | Type word is a side-story marker | See §4 |

Anything in the name before the type keyword is the scanlator/series prefix
and is discarded.

### 3. Numbering — two regimes

The regime is decided **per book**, from whether the book has any season
markers at all.

#### Regime A — book has ≥1 season marker → global renumbering

```
SEASONED = chapters with a season marker
LOOSE    = chapters without

Pass 1 — SEASONED
  sort by (season, number)
  group chapters sharing the same (season, number) into a tie group
  counter = 0
  for each group in order:
      counter += 1
      assigned = counter                      # integer chapter
      assigned = counter + frac              # decimal chapter, counter unchanged
      group shares ONE assigned number

Pass 2 — LOOSE (processed after everything else)
  - source number 0                     -> assigned 0, placed first (prologue)
  - seasons present start at 2+         -> fills the gap, placed first as Season 1
  - otherwise                           -> appended at the end, continuing the counter
```

Destination path:

```
book has 2+ distinct seasons  ->  "Season <n>/<Type> <assigned>"
book has exactly 1 season     ->  "<Type> <assigned>"          (flat)
```

#### Regime B — book has 0 season markers → source numbers preserved

No renumbering. The destination is `<Type> <source number>`, exactly as
v0.7 produces today. This is what keeps The Devil Butler (549 chapters) from
being rewritten.

**Exception — collision resolution.** If two chapters in a Regime B book would
resolve to the same number, the collision is a defect (the "Vanessa's story
chapter 1" case). The colliding chapter is treated as a side story and appended
at the end of the book, continuing from the book's current maximum number.

### 4. Side stories

A chapter is a side story if **either**:

- its chapter-name portion contains a side-story marker word (`Spin-off`,
  `Side Story`, `Bonus`, `Extra`, `Special`, `Omake`), **or**
- its number collides with a number already taken in the same book, and it is
  the *less canonical* of the two (see below).

**Canonical preference.** When two chapters in a book resolve to the same
number, the canonical one is the one with **less residual descriptive text**
once the type keyword and number are removed. Comparing the two full source
names works because the scanlator/series prefix is present in both and cancels
out:

```
Atsumaru (EN)_X_Alpha_Chapter 1          residual: "<prefix>"        → canonical
Atsumaru (EN)_X_Alpha_Vanessa's story Chapter 1
                                       residual: "<prefix> Vanessa's story"
                                                                  → side story
```

The non-canonical one is appended at the end of the book as a side story.

> A chapter with **no type word at all** — e.g. `Atsumaru (EN)_Black Butler_87`
> — is *not* automatically a side story. It keeps its bare number (`87`), which
> is the current behaviour minus the scanlator prefix. Inferring the book's
> dominant type word so it becomes `Episode 87` is a reasonable future
> enhancement but is explicitly deferred; the user called it "too complex" and
> later confirmed "just number them as we have been".

Side stories are processed **after** the main sequence is fully numbered, so
they can never take a slot in the middle of the story and cascade the rest of
the numbering.

They live at the **series root** (no folder wrapper) and are named
`<Type> <assigned>`. Kavita extracts the trailing number, so `Spin-off 219`
becomes chapter 219 and sorts after the main story in Mihon.

> A separate `Side Stories/` folder was considered and rejected: `Side Stories`
> does not match Kavita's volume pattern (`Volume N` / `Vol N` / `Season N`), so
> it would be parsed as a chapter folder and produce stranger nesting than the
> current state.

### 5. Tie groups and chapter replacement

Two source folders can describe the same chapter — e.g.
`..._Asura_Chapter 7 Season 1` and `..._Delta_Chapter 7 Season 1`, where the
user replaced the Asura version with the Delta version via Suwayomi.

- **Numbering:** a tie group (same season **and** same number) shares one
  assigned number, so the Delta chapter is never pushed into a different slot.
- **Content:** within a tie group the **newest source folder wins** (by
  mtime). The destination path for that group is removed before the winner is
  linked, so the destination ends up containing exactly the winner's files.
  The losers are superseded — they do not get a chapter of their own, and they
  are not pushed to the end of the book (they are the same chapter).

Tie-break when mtimes are equal: scanlator name descending, then folder name
descending. Deterministic either way.

> This also removes the two-cycle lag the current code has: `sync_series` runs
> before `purge_orphans`, so today a replaced chapter sits with stale hardlinks
> until the *next* rescan purges them. The new tie handling replaces the
> content in the same cycle.

**Distinction from §4:** a tie group is two source folders for the *same*
chapter (same season, same number) — the replacement case, where the loser is
superseded. A §4 collision is two *different* chapters that happen to land on
the same number (e.g. a side story numbered like a main chapter) — the
non-canonical one becomes a side story at the end of the book.

### 6. Legacy destination cleanup

When the destination layout changes (e.g. `Episode 1 S1` → `Season 1/Episode 1`),
the old directory keeps its hardlinks. Its inodes still exist in the source, so
`PURGE_ORPHANS` does **not** consider them orphans, and the `(EN)`-based
cleanup script does not match them either. Left alone, Kavita would see both
layouts and the duplicate-chapter problem would return.

**Design:** `sync_series` computes both the new destination path and the
legacy destination path (the v0.7 `sanitize_dir_name` result) for each
chapter. When they differ and the legacy path exists, the legacy path is
removed after the new path has been linked.

This makes booklinkarr the owner of the destination layout: any future rename
self-heals instead of requiring a manual step.

### 7. Bug fix — unsanitized fallthrough

`sanitize_dir_name` currently returns the input unchanged when no type keyword
matches. That is how `Atsumaru (EN)_Jungle Juice_Alpha_Spin-off 1` reached the
destination with its `(EN)` prefix.

**Change:** the fallthrough must never emit a name containing a scanlator or
locale tag. The fallthrough strips everything up to and including the scanlator
prefix and keeps only the chapter's own number (e.g. `87`). A name with a
side-story marker is handled by §4 instead and is named `<Type> <assigned>`.

The invariant: **no destination directory name may contain a locale tag
(`(EN)`, `(JP)`, …) or the scanlator/series prefix.**

### 8. Bug fix — fast-path cache race

The per-book scan cache (added for the slow-rescan work) stamps its cache file
with `now` at the end of a scan. A file downloaded *during* that scan has an
older mtime than the cache stamp, so the next scan sees "nothing newer" and
**permanently skips the file**.

**Change:** stamp the cache file with the **newest source file's mtime**, not
`now`. A file that arrived mid-scan is then still newer than the cache and
correctly triggers a cache miss.

### 9. Behaviour that must not change

- Book folder names still have digits stripped (`sanitize_book_name`).
- File names are not touched (extensions and numeric ordering preserved).
- Hardlink-only. No `cp` fallback.
- The inode cache / `PURGE_ORPHANS` machinery is unchanged.
- The inotify watcher still triggers a sync of the affected book immediately;
  the chapter-map pre-pass runs inside that sync, so latency is unchanged.

## Performance

The per-book pre-pass enumerates a book's **chapter folders** (K of them —
Jungle Juice has 227), parses each name, sorts, and assigns numbers: O(K log K)
on short strings. For K = 227 this is microseconds, against the per-**file**
work the script already does (Jungle Juice has ~10,000 files).

| Phase | Impact |
|---|---|
| Initial scan | + pre-pass per book (negligible). Chapters whose destination path changes are re-linked — 226 new hardlinks for Jungle Juice, one time. |
| Inode cache build | Unchanged. |
| Inode cache rebuild | Unchanged. |
| Rescan (warm cache) | Unchanged. The pre-pass only runs on a cache **miss**. |
| Inotify trigger | Unchanged latency — the pre-pass is inside the existing sync. |

The pre-pass must run on every slow-path sync (a new chapter changes the
numbering of everything after it), but it is bounded by chapter count, not
file count.

## Migration

1. Deploy the new image.
2. The first scan creates the new `Season N/` tree and removes the legacy flat
   `Episode N SN` folders (§6).
3. Kavita needs a library re-scan to pick up the new structure. The old
   chapters are removed and new ones created — **reading progress on Jungle
   Juice's chapters will reset**, since Kavita keys progress by chapter id.
   This is a one-time cost for this series; no other book on disk has season
   markers, so no other book is affected.
4. The diagnostic scripts used during this investigation are removed from the
   VM (`/home/carter117chief/docker/scripts/diagnose-*.sh`).

## Testing

### Unit-level (shell harness against a fixture tree)

| Case | Expected |
|---|---|
| `Atsumaru (EN)_X_Alpha_Episode 12 S2` | Season 2 / Episode 84 (in a 3-season book) |
| `Atsumaru (EN)_X_Alpha_Episode 83.5 S1` | Season 1 / Episode 83.5 |
| `Atsumaru (EN)_X_Alpha_Spin-off 1` | Spin-off 219 (appended, no `(EN)`) |
| `Atsumaru (EN)_X_Delta_Chapter 1` + `..._Asura_Chapter 1` | one destination; Delta wins (newer mtime) |
| `Atsumaru (EN)_X_Alpha_Episode 1` (no seasons in book) | Episode 1 — unchanged, no renumber |
| `Atsumaru (EN)_X_Alpha_Episode 0` (book has seasons) | Episode 0 — first |
| `Atsumaru (EN)_X_Alpha_Chapter 5` + `..._Alpha_Chapter 5` (no seasons) | one at Chapter 5, other appended at max+1 |
| `Atsumaru (EN)_X_Alpha_Vanessa's story Chapter 1` (no seasons) | appended at end (less canonical of the collision) |
| `Atsumaru (EN)_Black Butler_87` (no seasons) | `87` — bare number, prefix stripped, not a side story |
| `Atsumaru (EN)_Black Butler_87` (book has seasons) | appended with the loose chapters, type word preserved |
| `Atsumaru (EN)_X_Alpha_Episode 1 S2` in a book whose only season is S1 | flat `Episode 1` — no `Season` wrapper for single-season books |

### Integration (on VM444, after deploy)

1. `docker logs booklinkarr` shows the new naming, no `All N files already
   present` for Jungle Juice (it re-links).
2. `ls /data/media/books/webtoons/Jungle Juice` shows `Season 1`, `Season 2`,
   `Season 3` directories plus `Spin-off 219`…`Spin-off 225`, and **no**
   root-level `Episode N SN` folders.
3. Kavita DB check: `select Number, count(*) from Chapter ... group by Number
   having count(*) > 1` returns **zero rows** for Jungle Juice.
4. Mihon shows a flat, ascending chapter list with no duplicate names.
5. The Devil Butler is untouched — its 549 chapters keep their existing
   destination paths and destination chapter count is unchanged.
6. Fast-path: second rescan logs `✓ Cache hit:` for unchanged books.
7. Add a chapter to a source folder → inotify links it within seconds.
8. Replace a chapter with a different scanlator's folder → the destination
   contains the new scanlator's files after one cycle.

## Open items

- **Legacy cleanup mechanism** — §6 describes booklinkarr removing the legacy
  path. If that proves risky in testing, the fallback is a one-time manual
  command:
  ```bash
  find "/home/carter117chief/media-drive/data/media/books/webtoons/Jungle Juice" \
       -maxdepth 1 -type d -name "Episode * S[0-9]*" -exec rm -rf {} +
  ```
- **Tie-break order for equal mtimes** — proposed: scanlator name descending.

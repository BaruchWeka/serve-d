# serve-d memory on the weka repo — investigation + fixes

## Problem
`serve-d` grows to 10-20 GB RSS on the weka repo. Two instances OOM the laptop.

## Harness
`scratchpad/lspdrive.py` — stdio LSP client: initialize on one weka worktree, `didOpen`
`weka/cluster/node.d`, hover / definition / workspace-symbol, then poke every 35 s until RSS is
stable. `XDG_CACHE_HOME` is redirected so the user's real `~/.cache/serve-d` is never touched.
`scratchpad/idxmem` — loads `symbolindex.bin` through the real `IndexCache.load` and reports
`GC.stats()` per field.

## Where the memory was

| variant (cold cache, one worktree) | RSS |
|---|---|
| `d.enableIndex = false` | **82 MB** |
| `d.enableIndex = true` | **14 374 MB** |

The symbol index accounts for ~100 % of the balloon. Attribution at the same instant
(`GC.stats()` + `/proc/pid/smaps`):

| bucket | cold | warm (real 466 MB cache) |
|---|---|---|
| GC live | 1.1 GB | 3.7 GB |
| GC pools, free but unreturnable | 7.5 GB | 4.1 GB |
| glibc `[heap]`, never trimmed | 3.2 GB | 3.2 GB |
| glibc per-thread arenas (22 cores) | up to 2.9 GB | up to 2.9 GB |
| **RSS** | **11.5 - 14.4 GB** | **10.7 - 13.6 GB** |

Resulting index for one worktree: 35.8 MB. ~90 % of RSS was transient allocation the process
never handed back.

### Root causes

1. **`dirEntries` follows symlinks** (`index.d:appendSourceFiles`). bazel drops `bazel-bin`,
   `bazel-out`, `bazel-testlogs`, `bazel-<workspace>` into the worktree root, all pointing back
   into the sources being walked: **8 252 files walked for 4 412 distinct ones**.
2. **`autoIndexSources` queued all 9 195 files at once** and `whenAllDone` held every future, so
   every file's text and every file's definitions were live simultaneously.
3. **Every file was lexed twice** — `generateCacheEntry` built a whole token array only to test
   it wasn't empty, then the parser lexed it again.
4. **`symbolindex.bin` is global and only ever grew**: 466 MB, 59 477 entries, 5.44 M elements
   from ~15 checkouts of the same repo; 20 362 (34 %) pointed at deleted files. `IndexCache.load`
   deserialized all of it into **3 742 MB of live GC memory** before any indexing started.
5. **`DefinitionElement` is fat**: one `string[string]` AA per element (12.05 M entries but only
   11 distinct keys and 87 217 distinct key=value pairs) = 2 451 MB of the 3 742 MB; `name`
   another 535 MB for 79.6 MB of chars (201 855 distinct names).
6. **Nothing called `malloc_trim`**, so libdparse's malloc'd parse regions stayed mapped.

## Done

- [x] `serverbase: hand the C heap back after minimizing` — `malloc_trim(0)` next to `GC.minimize`
      and after the indexer finishes
- [x] `index: don't walk into symlinked directories` — `dirEntries(..., false)`
- [x] `index: bound the indexing work in flight, lex each file once` — batches of 64, single lex
- [x] `index: drop stale entries when loading the symbol cache` — skip entries `getIfActive`
      could never serve, rewrite the file without them; duplicate entries no longer nuke the cache

### Result

All figures from the same build recipe on both sides
(`dub build --compiler=ldc-1.42 --build-mode=allAtOnce`), same worktree, same harness.

| scenario | baseline | with fixes | |
|---|---|---|---|
| cold cache, `MALLOC_ARENA_MAX=1` | 11 051 MB | **2 236 MB** | −80 % |
| warm cache (real 466 MB index), `MALLOC_ARENA_MAX=1` | 11 688 MB (peak 13 800) | **2 876 MB** (peak 2 888) | −75 % |
| warm cache, the flags nvim actually passes, default arenas | 9 905 MB (peak **15 684**) | **3 038 MB** (peak 3 102) | −69 % steady, −80 % peak |

The peak is what OOMs the laptop: two instances went from a 31 GB spike to 6 GB.

| | baseline | with fixes |
|---|---|---|
| GC pause when it collects | 3.7 - 4.0 s | 0.7 - 2.1 s |
| cold indexing | 30.9 s | 16.7 s |
| warm indexing | 39.8 s | 3.7 s |
| index load | 8.3 s | 5.3 s |
| files walked | 9 195 | 4 583 |
| glibc `[heap]` | 3 215 MB | 39 MB |
| `symbolindex.bin` | 488 MB | 264 MB |
| live GC data (warm) | 5 422 MB | 2 004 MB |

`indexBatchSize` sweep (cold, `MALLOC_ARENA_MAX=1`) - the curve is shallow above 64, and
almost all of the win comes from having *any* bound:

| batch | steady | peak | indexing |
|---|---|---|---|
| unbounded (baseline) | 11 051 MB | 11 276 MB | 30.9 s |
| 256 | 2 704 MB | 5 503 MB | 16.5 s |
| **64** | **2 236 MB** | **4 910 MB** | **16.7 s** |
| 16 | 2 441 MB | 4 286 MB | 19.3 s |

Coverage change from the symlink fix: 4 105 → 4 039 modules. Most are bazel rule test fixtures
under `external/rules_d+/…`, but **not all of it is harmless**: the bazel build compiles against
an LDC from a docker image whose druntime is newer than the system one, and modules that only
exist there (`core.interpolation`, `core.stdc.stdatomic`, `core.sys.freebsd.net.if_`, …) are now
unindexed. They were reachable *only* through the `bazel-*` symlink walk - they are absent from
`/usr/lib/ldc/x86_64-linux-gnu/include/d`, which is the stdlib serve-d and dcd-server actually
use. That mismatch predates this change; the double-walk was hiding it.

Remedy, one config line - point serve-d at the toolchain the project builds with:

```
d.stdlibPath = ["/home/baruch/.cache/bazel/_bazel_baruch/<output-base>/external/+docker_image_ext+ldc-base/ldc2/include/d"]
```

Symlinked *roots* are still followed (`d.stdlibPath`, `d.extraRoots`, import paths); only
descending into symlinked subdirectories stops. So a project that symlinks a real source tree
into the workspace has to name it as a root.

The prune adds one more trigger for `save()`'s unlocked `File(fileName, "w")` full rewrite (the
first load after staleness passes 25 %). Full rewrites were already routine - `setFile` forces
one for any changed file - and the worst case of two instances racing is the corrupt-cache
rebuild `load` already catches, but that is the reason for the 25 % threshold rather than
rewriting whenever anything is stale.

`heapSizeFactor:4` in the nvim config is not worth changing: 3 038 MB with it vs 2 982 MB
without. `parallel:2` does help - it cuts the collect pause from 2.1 s to 0.7 s. Keep the line
as it is.

Tests: `dub test` for `:http`, `:lsp`, `:serverbase`, `workspace-d` and serve-d itself, before
and after. workspace-d 32→33 passing (the new `hasAnyParserToken` equivalence test) with the
same 2 pre-existing failures from a missing `test/data` dir; serve-d 22 passing with the same
pre-existing `served.linters.dscanner` failure.

All numbers above are debug (`--build-mode=allAtOnce`) builds on both sides. The binary at
`~/bin/serve-d` is a stripped release build; install with

```
dub build --compiler=~/dlang/ldc-1.42.0/bin/ldc2 --build=release && cp serve-d ~/bin/serve-d
```

after quitting the editors holding the current one. A release build should land at or below
these figures, but that was not measured.

## Remaining

Warm RSS is now 2 874 MB, of which **2 032 MB is live** — and `idxmem` on the new 264 MB cache
reproduces exactly that 2 032 MB, so the loaded global index *is* the remaining memory:

| | |
|---|---|
| `attributes` AAs | 1 334 MB |
| `name` / `versioned` | 327 MB |
| `elements[]` arrays | 359 MB |

Only 4 039 of the 36 233 loaded entries belong to the open workspace; ~89 % of that 2 GB is
other checkouts, deserialized purely so it can be written back out unchanged.

- [ ] **Not recommended: lazy element deserialization.** Recording each entry's byte range and
      unpacking on demand would take 2 032 MB → ~200 MB, but a lazy entry holds an offset into a
      file another serve-d instance may rewrite underneath it (`save` does an unlocked
      `File(fileName, "w")` on a global path). Today that race costs a corrupt-cache rebuild,
      which `load` already handles; with offsets it silently unpacks the wrong bytes. The user
      runs two instances - exactly the case where it bites.
- [ ] **Safer shape for the same 2 GB: make the cache per-workspace, or drop out-of-scope
      entries entirely on load** and accept that other checkouts reindex when reopened
      (~17 s cold). Policy decision, not a correctness hazard.
- [ ] Compact `attributes` (11 distinct keys, 87 217 distinct key=value pairs) - would take the
      2 032 MB to ~700 MB on its own without touching the concurrency question, but it needs a
      cache format bump (`serializeVersion` + the `hashFields` assert), which invalidates every
      existing cache.
- [ ] `forceReindexFromCache` deep-`dup`s every element (incl. the AA) into `cache`; transient
      now that `saveIndex` replaces them, but it is avoidable copying on the warm path.
- [ ] `workspaced.stringCache` is one `StringCache` shared unsynchronized across the 6 indexing
      threads — pre-existing, but a genuine data race.
- [ ] Pool fragmentation is now the largest cold bucket: 1 920 MB free in GC pools against
      360 MB live. `GC.minimize` can't return a pool that holds one live page.

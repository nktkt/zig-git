# Git → Zig Migration Roadmap

## Project Overview

An incremental port of git (C implementation) to Zig.
Phases are divided by LOC (Lines of Code), with each phase producing an independently functional deliverable.

## Current Codebase Scale

| Language | Files | LOC | Notes |
|----------|-------|-----|-------|
| C (.c) | 629 | 383,211 | Core implementation |
| C (.h) | 338 | 51,075 | Headers |
| Shell (.sh) | 1,279 | 330,746 | 1,208 tests + scripts |
| Perl (.perl/.pm) | 47 | 33,236 | git-svn, git-send-email, etc. |
| Python (.py) | 3 | 5,035 | Auxiliary tools |
| Documentation | - | 140,023 | Manuals |
| **C total** | **967** | **434,286** | **Port target** |

## Functional LOC Breakdown (C)

| Functional Group | LOC | Share | Key Files |
|-----------------|-----|-------|-----------|
| CLI/Porcelain (builtin/) | 94,541 | 21.8% | pack-objects(5302), fast-import(3997), submodule--helper(3836), gc(3535), fetch(2883) |
| Object Storage | 13,774 | 3.2% | object-file, packfile, pack-bitmap, commit-graph |
| Refs | 21,162 | 4.9% | refs.c(3553), refs/*, reftable/* |
| Diff/Merge | 17,765 | 4.1% | diff(7576), merge-ort(5602), xdiff/* |
| Index | 11,322 | 2.6% | read-cache(4065), unpack-trees(3071), dir(4186) |
| Network | 10,551 | 2.4% | remote(2965), http(2959), fetch-pack(2297) |
| Config/Setup | 7,178 | 1.7% | config(3594), setup(2860) |
| Compat/Platform | 6,862 + 33,971 | 9.4% | compat/* (OS abstraction layer) |
| Other core | ~123,000 | ~28% | sequencer, apply, blame, grep, convert, etc. |
| Top-level headers | 51,075 | 11.8% | Data structure definitions |
| Tests (t/*.c) | 23,584 | 5.4% | C unit tests |

---

## Phase Structure

### Phase 0: Foundation
**Target LOC: ~15,000 Zig (new)**
**Estimated duration: 2–3 months**
**Dependencies: None**

Build the Zig project skeleton and git's fundamental data structures.

| Task | Source LOC | Output |
|------|-----------|--------|
| Build system (build.zig) | - | Native Zig build |
| SHA-1 / SHA-256 hashing | 2,445 + 339 (sha1dc/, sha256/) | `hash.zig` |
| zlib compression/decompression | Part of compat | Zig std library or C linkage |
| Core type definitions (object_id, strbuf equivalent) | ~3,000 (headers) | `types.zig` |
| Memory allocator abstraction | Scattered | Zig allocator interface |
| Error handling patterns | Scattered | Zig error union design |

**Milestone:** SHA-256 binary runs. Benchmarkable against C implementation.

---

### Phase 1: Object Layer
**Target LOC: ~20,000 Zig**
**Source LOC: ~13,774 + headers**
**Estimated duration: 3–4 months**
**Dependencies: Phase 0**

The heart of git. Read/write blob, tree, commit, and tag objects.

| Task | Source File | LOC |
|------|------------|-----|
| Loose object read/write | object-file.c | 2,275 |
| Object name resolution | object-name.c | 2,188 |
| Pack file reading | packfile.c | 2,691 |
| Pack index | midx-write.c, midx.c | ~3,500 |
| Pack bitmap | pack-bitmap.c | 3,420 |
| Commit graph | commit-graph.c | 2,932 |
| Object iteration | object.c, tag.c, tree.c, blob.c | ~2,500 |

**Milestone:** `zig-git cat-file -p <sha>` works. Can read objects from existing repositories.

---

### Phase 2: Index & Working Tree
**Target LOC: ~15,000 Zig**
**Source LOC: ~11,322**
**Estimated duration: 2–3 months**
**Dependencies: Phase 1**

| Task | Source File | LOC |
|------|------------|-----|
| Index (staging area) read/write | read-cache.c | 4,065 |
| Tree unpacking/comparison | unpack-trees.c | 3,071 |
| Directory traversal / exclude patterns | dir.c | 4,186 |

**Milestone:** `zig-git status` works (including diff display).

---

### Phase 3: Refs
**Target LOC: ~22,000 Zig**
**Source LOC: ~21,162**
**Estimated duration: 3–4 months**
**Dependencies: Phase 1**

| Task | Source File | LOC |
|------|------------|-----|
| Refs abstract API | refs.c | 3,553 |
| Files backend | refs/files-backend.c | ~3,500 |
| Packed refs | refs/packed-backend.c | ~2,500 |
| Reftable backend | reftable/*.c | 9,097 |
| Reflog | refs/debug.c, iterator | ~2,500 |

**Milestone:** `zig-git branch`, `zig-git tag` work.

---

### Phase 4: Diff & Merge
**Target LOC: ~20,000 Zig**
**Source LOC: ~17,765**
**Estimated duration: 3–4 months**
**Dependencies: Phase 1, 2**

| Task | Source File | LOC |
|------|------------|-----|
| Diff core | diff.c | 7,576 |
| Diff library | diff-lib.c, diffcore-*.c | ~3,000 |
| xdiff (Myers/patience/histogram) | xdiff/*.c | 4,363 |
| Merge ORT | merge-ort.c | 5,602 |

**Milestone:** `zig-git diff`, `zig-git merge` work.

---

### Phase 5: Config & Setup
**Target LOC: ~8,000 Zig**
**Source LOC: ~7,178**
**Estimated duration: 1–2 months**
**Dependencies: Phase 0**

| Task | Source File | LOC |
|------|------------|-----|
| Config parser/writer | config.c | 3,594 |
| Repository detection/initialization | setup.c | 2,860 |
| Environment variables | environment.c | 724 |

**Milestone:** `zig-git init`, `zig-git config` work.

---

### Phase 6: Network
**Target LOC: ~12,000 Zig**
**Source LOC: ~10,551**
**Estimated duration: 2–3 months**
**Dependencies: Phase 1, 3**

| Task | Source File | LOC |
|------|------------|-----|
| Remote management | remote.c | 2,965 |
| HTTP transport | http.c | 2,959 |
| Pack protocol (fetch) | fetch-pack.c | 2,297 |
| Pack protocol (push) | send-pack.c | ~1,500 |
| Transport abstraction | transport.c, connect.c | ~2,000 |

**Milestone:** `zig-git clone`, `zig-git fetch`, `zig-git push` work.

---

### Phase 7: Porcelain Commands (First Half)
**Target LOC: ~35,000 Zig**
**Source LOC: ~47,000 (top half of builtin/)**
**Estimated duration: 4–6 months**
**Dependencies: Phase 1–6**

High-frequency commands first.

| Priority | Command | Source File | LOC |
|----------|---------|------------|-----|
| P0 | add, commit, status | builtin/add.c, commit.c, wt-status.c | ~5,700 |
| P0 | log, show | builtin/log.c, pretty.c, revision.c | ~9,300 |
| P0 | checkout, switch | builtin/checkout.c | 2,162 |
| P0 | branch | builtin/branch.c | ~800 |
| P1 | clone, fetch, push | builtin/clone.c, fetch.c, push.c | ~5,500 |
| P1 | merge, rebase | builtin/merge.c, rebase.c | ~3,800 |
| P1 | stash | builtin/stash.c | 2,445 |
| P1 | cherry-pick, revert | sequencer.c | 6,884 |
| P1 | am | builtin/am.c | 2,560 |

**Milestone:** A full daily workflow (clone → branch → edit → commit → push) completes end-to-end.

---

### Phase 8: Porcelain Commands (Second Half)
**Target LOC: ~30,000 Zig**
**Source LOC: ~47,000 (remaining builtin/)**
**Estimated duration: 4–6 months**
**Dependencies: Phase 7**

| Priority | Command | LOC |
|----------|---------|-----|
| P2 | pack-objects, index-pack | 5,302 + 2,149 |
| P2 | gc, maintenance | 3,535 |
| P2 | fast-import/export | 3,997 |
| P2 | submodule | 3,836 |
| P2 | bisect | 1,489 |
| P2 | worktree | 1,493 |
| P3 | blame, annotate | 2,950 |
| P3 | grep | 2,018 |
| P3 | archive, bundle | ~1,500 |
| P3 | fsmonitor | 1,607 |
| P3 | All remaining builtins | ~17,000 |

**Milestone:** 90%+ of git's test suite passes.

---

### Phase 9: Platform Compat
**Target LOC: ~10,000 Zig (major reduction)**
**Source LOC: ~33,971 (compat/)**
**Estimated duration: 2–3 months**
**Dependencies: Phase 0–8**

Zig's cross-compilation capabilities eliminate most of C git's compat/ layer.

| Task | Notes |
|------|-------|
| Windows support | Zig's std.fs and std.os handle abstraction. Most of compat/mingw.c (5,000+ lines) becomes unnecessary |
| macOS support | iconv, regex, etc. only |
| Linux support | Minimal |

**Milestone:** All tests pass on Linux/macOS/Windows.

---

### Phase 10: Test Suite Migration
**Target LOC: ~50,000 Zig tests**
**Source LOC: ~314,672 (shell) + 23,584 (C)**
**Estimated duration: Ongoing, parallel to all phases**

| Strategy | Details |
|----------|---------|
| Incremental migration | Convert corresponding shell tests to Zig tests as each phase completes |
| Compatibility layer | Initially run existing shell tests as-is (swap binary name only) |
| Zig-native tests | Unit test internal APIs with `zig test` |

---

## Overall Timeline

```
Phase 0: Foundation         ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░  [~15K Zig]
Phase 5: Config/Setup         ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░  [~8K Zig]
Phase 1: Object Layer           ██████░░░░░░░░░░░░░░░░░░░░░░░░  [~20K Zig]
Phase 2: Index/Tree                █████░░░░░░░░░░░░░░░░░░░░░░  [~15K Zig]
Phase 3: Refs                      ██████░░░░░░░░░░░░░░░░░░░░░  [~22K Zig]
Phase 4: Diff/Merge                   ██████░░░░░░░░░░░░░░░░░░  [~20K Zig]
Phase 6: Network                         █████░░░░░░░░░░░░░░░░  [~12K Zig]
Phase 7: Porcelain (core)                    █████████░░░░░░░░░  [~35K Zig]
Phase 8: Porcelain (full)                             █████████  [~30K Zig]
Phase 9: Platform Compat                                 ██████  [~10K Zig]
Phase 10: Tests               ─────────────────────────────────  [ongoing]
                              M1  M3  M6  M9  M12 M15 M18 M21 M24
```

## LOC Summary

| Category | C (original) | Zig (estimated) | Ratio | Reason |
|----------|-------------|-----------------|-------|--------|
| Core implementation | 434,286 | ~187,000 | 0.43x | Zig expressiveness, compat layer elimination, no headers |
| Tests | 338,256 | ~50,000 (Zig) + existing shell | - | Shell test reuse |
| **Total port target** | **434,286** | **~187,000** | - | - |

### Why Zig LOC Is Lower

1. **No headers** (-51,075): Zig's module system unifies declaration and implementation
2. **Major compat/ reduction** (-24,000): Zig std absorbs OS differences
3. **Simplified strbuf/string handling** (-est. 10,000): Naturally expressed with Zig slices and allocators
4. **Macro elimination** (-est. 5,000): Zig comptime replaces C preprocessor tricks with type safety
5. **Simplified error handling**: The `if (ret < 0) goto cleanup` pattern becomes a single `try`

## Why Zig (for a git port specifically)

| Advantage | Concrete Effect on git |
|-----------|----------------------|
| Full C ABI compatibility | Link existing libz, libcurl, openssl directly. Enables incremental migration |
| Built-in cross-compilation | Eliminates most of the 33,971-line compat/ directory |
| Comptime | Compile-time optimized pack format parsing, hash algorithm selection |
| Safety | Prevents buffer overflows — the #1 cause of git CVEs — through type system |
| Build speed | build.zig replaces make/autoconf/cmake entirely |
| Built-in testing | `zig test` eliminates the need for C-era test infrastructure |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zig itself is pre-1.0 | Build breakage | Pin Zig version; CI tests both nightly and stable |
| libcurl/openssl dependency | Affects network layer migration | Link C libraries through Phase 6; evaluate zig-http later |
| Git wire protocol compatibility | Broken fetch/push | Run existing test suite against zig-git binary for verification |
| Solo contributor scale limits | Phase 7+ is massive | Phase 6 completion = MVP (minimally usable git); invite community participation beyond that |

## Reference: Existing Git Reimplementations

| Project | Language | LOC | Compatibility | Notes |
|---------|----------|-----|---------------|-------|
| libgit2 | C | ~200K | Library only (no CLI) | Used by GitHub Desktop, etc. |
| gitoxide (gix) | Rust | ~250K | CLI + library | Most complete alternative. Key architectural reference |
| go-git | Go | ~80K | Library-focused | Pure Go implementation |
| JGit | Java | ~300K | Eclipse ecosystem | Java implementation |
| **This project** | **Zig** | **~187K (est.)** | **Full CLI compatibility** | - |

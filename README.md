# zig-git

A ground-up reimplementation of [Git](https://git-scm.com/) in [Zig](https://ziglang.org/).

## Why

Git is 434K lines of C — battle-tested but showing its age. Buffer overflows remain its #1 CVE category, the build system spans autoconf/make/cmake, and `compat/` carries 34K lines of platform shims.

Zig is a natural successor for this kind of systems software:

- **C ABI compatible** — link existing libz, libcurl, openssl directly; migrate incrementally
- **Cross-compilation built in** — eliminates most of the 34K-line `compat/` layer
- **Comptime** — compile-time optimized pack format parsing, hash selection
- **Memory safety** — bounds-checked slices, no hidden allocations, explicit allocators
- **Built-in test runner** — no external test harness needed
- **Single-file build** — `build.zig` replaces autoconf + make + cmake

## Scope

Full CLI-compatible git replacement. Not a library-only project (like libgit2), not a partial implementation — the goal is `alias git=zig-git`.

## LOC Analysis

Based on analysis of [git/git](https://github.com/git/git) (current master):

| Language | Files | LOC | Notes |
|----------|-------|-----|-------|
| C (.c) | 629 | 383,211 | Core implementation |
| C (.h) | 338 | 51,075 | Headers |
| Shell (.sh) | 1,279 | 330,746 | 1,208 tests + scripts |
| Perl | 47 | 33,236 | git-svn, git-send-email, etc. |
| **C total** | **967** | **434,286** | **Port target** |

### Estimated Zig LOC: ~187,000 (0.43x reduction)

Why the reduction:
- **No headers** (-51K): Zig modules unify declaration and implementation
- **No compat/ layer** (-24K): Zig std abstracts OS differences
- **No strbuf boilerplate** (-10K): Zig slices + allocator interface
- **No macro gymnastics** (-5K): comptime replaces C preprocessor hacks
- **Error handling**: `if (ret < 0) goto cleanup` → `try`

## Functional Breakdown

| Component | C LOC | Key files |
|-----------|-------|-----------|
| CLI / Porcelain | 94,541 | `builtin/*.c` (70+ commands) |
| Object Storage | 13,774 | `object-file.c`, `packfile.c`, `pack-bitmap.c`, `commit-graph.c` |
| Refs | 21,162 | `refs.c`, `refs/*`, `reftable/*` |
| Diff / Merge | 17,765 | `diff.c` (7,576), `merge-ort.c` (5,602), `xdiff/*` |
| Index / Working Tree | 11,322 | `read-cache.c`, `unpack-trees.c`, `dir.c` |
| Network | 10,551 | `remote.c`, `http.c`, `fetch-pack.c`, `send-pack.c` |
| Config / Setup | 7,178 | `config.c` (3,594), `setup.c` (2,860) |
| Platform Compat | 33,971 | `compat/*` (mostly eliminated in Zig) |
| Other core | ~123,000 | `sequencer.c`, `apply.c`, `blame.c`, `grep.c`, etc. |

## Roadmap

10 phases over ~24 months, ordered by dependency graph:

```
Phase 0: Foundation         ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ~15K Zig
Phase 5: Config/Setup         ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ~8K Zig
Phase 1: Object Layer           ██████░░░░░░░░░░░░░░░░░░░░░░░░  ~20K Zig
Phase 2: Index/Tree                █████░░░░░░░░░░░░░░░░░░░░░░  ~15K Zig
Phase 3: Refs                      ██████░░░░░░░░░░░░░░░░░░░░░  ~22K Zig
Phase 4: Diff/Merge                   ██████░░░░░░░░░░░░░░░░░░  ~20K Zig
Phase 6: Network                         █████░░░░░░░░░░░░░░░░  ~12K Zig
Phase 7: Porcelain (core)                    █████████░░░░░░░░░  ~35K Zig
Phase 8: Porcelain (full)                             █████████  ~30K Zig
Phase 9: Platform                                        ██████  ~10K Zig
Tests:                        ─────────────────────────────────  ongoing
                              M1  M3  M6  M9  M12 M15 M18 M21 M24
```

### Phase 0 — Foundation (~15K Zig)

Build system (`build.zig`), SHA-1/SHA-256, zlib compression, core types (`ObjectId`, string buffers), allocator abstractions, error handling patterns.

**Milestone:** SHA-256 binary runs. Benchmarkable against C.

### Phase 1 — Object Layer (~20K Zig)

Loose objects, pack files, pack index, pack bitmap, commit graph, object iteration.

**Milestone:** `zig-git cat-file -p <sha>` reads from existing repositories.

### Phase 2 — Index & Working Tree (~15K Zig)

Index read/write, tree unpacking/comparison, directory traversal, ignore patterns.

**Milestone:** `zig-git status` works.

### Phase 3 — Refs (~22K Zig)

Ref abstraction API, files backend, packed-refs, reftable backend, reflog.

**Milestone:** `zig-git branch`, `zig-git tag` work.

### Phase 4 — Diff & Merge (~20K Zig)

Diff core, diff library, xdiff algorithms (Myers/patience/histogram), merge-ort.

**Milestone:** `zig-git diff`, `zig-git merge` work.

### Phase 5 — Config & Setup (~8K Zig)

Config parser/writer, repository detection/initialization, environment variables.

**Milestone:** `zig-git init`, `zig-git config` work.

### Phase 6 — Network (~12K Zig)

Remote management, HTTP transport, pack protocol (fetch/push), transport abstraction.

**Milestone:** `zig-git clone`, `zig-git fetch`, `zig-git push` work. **This is the MVP — a minimally usable git.**

### Phase 7 — Porcelain, Core Commands (~35K Zig)

High-frequency commands first:

| Priority | Commands | C LOC |
|----------|----------|-------|
| P0 | add, commit, status | ~5,700 |
| P0 | log, show | ~9,300 |
| P0 | checkout, switch | 2,162 |
| P0 | branch | ~800 |
| P1 | clone, fetch, push | ~5,500 |
| P1 | merge, rebase | ~3,800 |
| P1 | stash, cherry-pick, revert, am | ~11,900 |

**Milestone:** Full daily workflow (clone → branch → edit → commit → push) works end-to-end.

### Phase 8 — Porcelain, Full Coverage (~30K Zig)

pack-objects, gc, fast-import/export, submodule, bisect, worktree, blame, grep, archive, bundle, fsmonitor, and all remaining builtins.

**Milestone:** 90%+ of git's test suite passes.

### Phase 9 — Platform Compat (~10K Zig)

Linux, macOS, Windows. Zig's cross-compilation dramatically reduces this — C git's `compat/` is 34K lines; we expect ~10K.

**Milestone:** All tests pass on Linux/macOS/Windows.

## Prior Art

| Project | Language | LOC | Compatibility |
|---------|----------|-----|---------------|
| [libgit2](https://github.com/libgit2/libgit2) | C | ~200K | Library only (no CLI) |
| [gitoxide](https://github.com/GitoxideLabs/gitoxide) | Rust | ~250K | CLI + library, most complete alternative |
| [go-git](https://github.com/go-git/go-git) | Go | ~80K | Library-focused |
| [JGit](https://eclipse.dev/jgit/) | Java | ~300K | Eclipse ecosystem |
| **zig-git** | **Zig** | **~187K est.** | **Full CLI compatibility** |

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zig is pre-1.0 | Build breakage on upgrades | Pin Zig version; CI tests both stable and nightly |
| libcurl/openssl dependency | Network layer complexity | Link C libraries initially; evaluate zig-http later |
| Wire protocol compatibility | Broken fetch/push | Run existing shell test suite against zig-git binary |
| Scale (187K lines) | Stalls after MVP | Phase 6 = MVP; open to contributors after that |

## Building

> **Note:** This project is in the planning stage. No Zig code exists yet.

```bash
# When ready:
zig build
zig build test
```

## License

TBD — likely GPL-2.0 (matching upstream git) or MIT.

## Detailed Roadmap

See [GIT_ZIG_ROADMAP.md](./GIT_ZIG_ROADMAP.md) for the full LOC-based analysis with per-file breakdowns.

# zig-git

A ground-up reimplementation of [Git](https://git-scm.com/) in [Zig](https://ziglang.org/).

**57,900+ lines of Zig** across 123 source files. **60+ commands** implemented. Full daily workflow works: `init → add → commit → branch → checkout → diff → merge → log → clone`. Repository format is **100% compatible with git** — git can read zig-git repos and vice versa.

## Quick Start

```bash
zig build
./zig-out/bin/zig-git init my-repo
cd my-repo
zig-git add .
zig-git commit -m "Hello from zig-git"
zig-git log
```

**Requirements:** Zig 0.15+, zlib (`brew install zig` on macOS covers both)

## What Works

### Core Workflow (fully tested, git-compatible output)

```
zig-git init            # Create repository
zig-git add <files>     # Stage changes (respects .gitignore)
zig-git commit -m "msg" # Create commits (-a, --amend, --allow-empty)
zig-git status          # Show staged/unstaged/untracked (--short format)
zig-git diff            # Unified diff with color (--cached, commit range)
zig-git log             # Commit history (--oneline, --graph, -n, --format=)
zig-git show <commit>   # Commit details with diff
zig-git branch [-v]     # List/create/delete branches
zig-git checkout <ref>  # Switch branches (-b to create)
zig-git merge <branch>  # Fast-forward merge + three-way merge
zig-git tag [name]      # Lightweight + annotated tags
zig-git stash           # Save/restore working directory (push/pop/list/apply)
zig-git reset           # --soft/--mixed/--hard
zig-git cherry-pick     # Apply commits across branches
zig-git clone <path>    # Local clone (objects + refs + working tree)
```

### Extended Commands

| Category | Commands |
|----------|----------|
| **Search** | `grep`, `blame` |
| **History** | `cherry-pick`, `rebase`, `bisect`, `shortlog`, `range-diff` |
| **Files** | `rm`, `mv`, `clean`, `archive` |
| **Remote** | `remote`, `fetch`, `push` (local protocol) |
| **Submodule** | `submodule` (init/update/add/status/sync/deinit/foreach) |
| **Patch** | `apply`, `format-patch`, `am`, `send-email` |
| **Maintenance** | `gc`, `repack`, `prune`, `fsck`, `pack-refs`, `maintenance` |
| **Plumbing** | `cat-file`, `hash-object`, `rev-parse`, `ls-files`, `ls-tree`, `write-tree`, `read-tree`, `update-index`, `for-each-ref`, `diff-tree`, `diff-files`, `diff-index`, `rev-list`, `merge-base`, `name-rev`, `symbolic-ref`, `check-ignore`, `verify-pack`, `verify-commit`, `verify-tag` |
| **Advanced** | `notes`, `describe`, `count-objects`, `worktree`, `sparse-checkout`, `bundle`, `rerere`, `filter-branch`, `credential`, `mktag`, `mktree`, `commit-tree`, `var` |
| **Config** | `config` (--local/--global/--system, includes, conditional includes) |
| **Infrastructure** | Git protocol v1/v2, HTTP/SSH transport (via curl/ssh), pkt-line, refspec, .gitattributes, hooks, .mailmap, pathspec magic |

### Git Interop

zig-git produces byte-identical object storage. Repositories created by zig-git are fully readable by git, and zig-git can read any standard git repository (loose objects + pack files with delta chains).

```bash
# Create with zig-git, verify with git
zig-git init repo && cd repo
zig-git commit --allow-empty -m "test"
git log   # works perfectly
```

## Architecture

```
src/
├── main.zig            # CLI entry point (60+ commands)
├── types.zig           # ObjectId, ObjectType, core types
├── repository.zig      # Repo discovery, object lookup, ref resolution
├── hash.zig            # SHA-1/SHA-256
├── compress.zig        # zlib via C linkage
│
├── loose.zig           # Loose object read/write
├── pack.zig            # Pack file reader (delta resolution)
├── pack_index.zig      # Pack index v2 (mmap + binary search)
├── pack_objects.zig    # Pack writer with delta compression
├── pack_bitmap.zig     # EWAH bitmap reader
├── commit_graph.zig    # Commit-graph reader
├── commit_graph_write.zig # Commit-graph writer
│
├── index.zig           # Git index (DIRC format)
├── index_ext.zig       # Index extensions (TREE, REUC, EOIE, IEOT)
├── ignore.zig          # .gitignore pattern matching
├── attributes.zig      # .gitattributes
│
├── ref.zig             # Ref CRUD (loose + packed-refs)
├── refspec.zig         # Refspec parsing and matching
├── reflog.zig          # Reflog read/write
│
├── diff.zig            # Myers diff + unified output
├── tree_diff.zig       # Recursive tree comparison
├── patience_diff.zig   # Patience/histogram diff
├── word_diff.zig       # Word-level diff
├── diff_rename.zig     # Rename/copy detection
├── diff_stat.zig       # --stat/--numstat/--dirstat
├── delta.zig           # Git delta format (apply)
│
├── merge.zig           # Three-way merge + conflict markers
├── merge_strategies.zig # ours/theirs/recursive strategies
├── merge_base.zig      # LCA finding in commit DAG
│
├── transport.zig       # Transport abstraction
├── http_transport.zig  # Smart HTTP (via curl)
├── ssh_transport.zig   # SSH (via ssh subprocess)
├── pkt_line.zig        # Git pkt-line protocol
├── protocol_v2.zig     # Git protocol v2
├── capabilities.zig    # Protocol capability negotiation
├── url.zig             # Git URL parsing
│
├── config.zig          # INI-like config parser
├── config_ext.zig      # --global/--system, includes
├── hooks.zig           # Git hooks execution
├── mailmap.zig         # .mailmap support
├── color.zig           # ANSI color management
├── progress.zig        # Progress bars
├── trace.zig           # GIT_TRACE debug system
├── pathspec.zig        # Advanced pathspec matching
│
└── [30+ command files]  # add, commit, log, checkout, merge, etc.
```

## Why Zig

| Advantage | Effect on git |
|-----------|--------------|
| **C ABI compatible** | Link existing libz directly. Incremental migration possible |
| **Cross-compilation** | Eliminates 34K-line `compat/` layer |
| **Comptime** | Compile-time optimized pack format parsing |
| **Memory safety** | Prevents buffer overflows — git's #1 CVE category |
| **Single-file build** | `build.zig` replaces autoconf + make + cmake |
| **No hidden allocations** | Explicit allocator threading catches leaks at dev time |

## LOC Comparison

| Implementation | Language | LOC | Status |
|----------------|----------|-----|--------|
| [git/git](https://github.com/git/git) | C | 434,286 | Reference implementation |
| [gitoxide](https://github.com/GitoxideLabs/gitoxide) | Rust | ~250,000 | Most complete alternative |
| [JGit](https://eclipse.dev/jgit/) | Java | ~300,000 | Eclipse ecosystem |
| [go-git](https://github.com/go-git/go-git) | Go | ~80,000 | Library-focused |
| [libgit2](https://github.com/libgit2/libgit2) | C | ~200,000 | Library only (no CLI) |
| **zig-git** | **Zig** | **57,904** | **60+ commands, daily workflow works** |

## Current Limitations

- **Network:** `fetch`/`push` work with local paths only. HTTP/SSH transport infrastructure exists but is not battle-tested against GitHub/GitLab
- **Merge:** Three-way merge works for common cases. Complex conflicts (criss-cross merges, rename conflicts) may not resolve identically to git
- **Performance:** Not yet benchmarked or optimized. No parallel pack decompression
- **Platform:** Tested on macOS (ARM64). Linux should work. Windows untested
- **Interactive:** `rebase -i`, `add -p` have basic implementations but lack full terminal interaction

## Building

```bash
# Build
zig build

# Run
./zig-out/bin/zig-git <command>

# Run tests
zig build test

# Build optimized
zig build -Doptimize=ReleaseFast
```

## Project Structure

- `src/` — All 123 Zig source files (57,904 lines)
- `build.zig` — Build configuration
- `GIT_ZIG_ROADMAP.md` — Detailed migration roadmap with per-file LOC analysis

## License

MIT

## Detailed Roadmap

See [GIT_ZIG_ROADMAP.md](./GIT_ZIG_ROADMAP.md) for the full LOC-based analysis of git/git and the original migration plan.

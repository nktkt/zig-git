# zig-git

A ground-up reimplementation of [Git](https://git-scm.com/) in [Zig](https://ziglang.org/).

**63,000+ lines of Zig** across 132 source files. **65+ commands** implemented. Full daily workflow works end-to-end, including **HTTPS clone/fetch/push against GitHub**. Repository format is **100% compatible with git**.

## Quick Start

```bash
zig build
./zig-out/bin/zig-git clone https://github.com/octocat/Hello-World.git
cd Hello-World
zig-git log --oneline
```

Or start from scratch:

```bash
./zig-out/bin/zig-git init my-repo && cd my-repo
zig-git add .
zig-git commit -m "Hello from zig-git"
zig-git log
zig-git remote add origin https://github.com/you/repo.git
zig-git push -u origin master
```

**Requirements:** Zig 0.15+, zlib, curl (for HTTPS), ssh (for SSH transport)

## What Works

### Core Workflow

| Command | Features |
|---------|----------|
| `init` | `--bare`, `-b <branch>` |
| `add` | `.`, `-A`, `-p` (interactive), `.gitignore` support |
| `commit` | `-m`, `-a`, `--amend`, `--allow-empty`, editor launch without `-m` |
| `status` | Staged / unstaged / untracked (short format) |
| `diff` | Unified diff, `--cached`, `--stat`, `--word-diff`, `--color-words` |
| `log` | `--oneline`, `--graph`, `--all`, `--format=`, `--decorate`, `-p`, `-n` |
| `show` | Commit details with diff |
| `branch` | `-v`, `-d`, create |
| `checkout` | `-b`, detached HEAD, `-- <file>` |
| `switch` | `-c`, `-C`, `-d`, `-` (previous branch) |
| `merge` | Fast-forward, three-way with conflict markers, `--no-commit`, `--squash` |
| `rebase` | `--abort`, `--continue`, `--skip`, `--onto` |
| `tag` | Lightweight, annotated (`-a -m`), `--sort=version:refname` |
| `stash` | `push`, `pop`, `apply`, `list`, `drop` |
| `reset` | `--soft`, `--mixed`, `--hard`, `-p` |
| `restore` | `--staged`, `--source=<commit>`, `--worktree` |
| `cherry-pick` | `--abort`, `--continue` |

### Network (HTTPS + SSH + Local)

| Command | Features |
|---------|----------|
| `clone` | HTTPS, SSH (`git@host:path`), local paths, `file://` |
| `fetch` | HTTPS, local. Updates remote tracking refs |
| `push` | HTTPS, local. `--set-upstream`, `--force` |
| `pull` | fetch + merge. `--rebase`, `--ff-only` |
| `remote` | `add`, `remove`, `-v` |

```bash
# Clone from GitHub over HTTPS
zig-git clone https://github.com/octocat/Hello-World.git

# Push (with token auth in URL)
zig-git push https://user:token@github.com/user/repo.git master
```

### Extended Commands

| Category | Commands |
|----------|----------|
| **Search** | `grep` (`-i`, `-n`, `-c`, `-l`), `blame` (`-L`) |
| **History** | `cherry-pick`, `rebase`, `bisect`, `shortlog`, `range-diff` |
| **Files** | `rm`, `mv`, `clean` (`-f`, `-n`, `-d`), `archive` (tar) |
| **Submodule** | `submodule` (init/update/add/status/sync/deinit/foreach) |
| **Patch** | `apply`, `format-patch`, `am`, `send-email` |
| **Maintenance** | `gc`, `repack`, `prune`, `fsck`, `pack-refs`, `maintenance` |
| **Advanced** | `notes`, `describe`, `count-objects`, `worktree`, `sparse-checkout`, `bundle`, `rerere`, `filter-branch`, `credential`, `var` |
| **Config** | `config` (`--local`/`--global`/`--system`, includes, conditional includes, aliases) |

### Plumbing

`cat-file`, `hash-object`, `rev-parse`, `ls-files`, `ls-tree`, `write-tree`, `read-tree`, `update-index`, `for-each-ref`, `diff-tree`, `diff-files`, `diff-index`, `rev-list`, `merge-base`, `name-rev`, `symbolic-ref`, `check-ignore`, `check-attr`, `verify-pack`, `verify-commit`, `verify-tag`, `mktag`, `mktree`, `commit-tree`

### Infrastructure

- Git protocol v1/v2
- Smart HTTP transport (via curl)
- SSH transport (via ssh subprocess)
- Pkt-line protocol, refspec matching
- `.gitattributes`, `.gitignore`, `.mailmap`
- Git hooks execution
- Pager integration (less)
- Editor integration (for commit messages)
- Alias support
- ANSI color output (auto-detect TTY)
- Progress reporting
- GIT_TRACE debug system

### Git Interop

zig-git produces byte-identical object storage. Repositories created by zig-git are fully readable by git, and vice versa.

```bash
# Create with zig-git, verify with git
zig-git init repo && cd repo
echo "hello" > file.txt
zig-git add file.txt && zig-git commit -m "test"
git log    # identical output
git status # clean
```

## Architecture

```
src/
├── main.zig               # CLI entry (65+ commands, alias resolution)
├── types.zig              # ObjectId, ObjectType, core types
├── repository.zig         # Repo discovery, object lookup, ref resolution
├── hash.zig               # SHA-1/SHA-256
├── compress.zig           # zlib via C linkage
│
│ ── Object Storage ──
├── loose.zig              # Loose object read/write
├── pack.zig               # Pack file reader (delta chain resolution)
├── pack_index.zig         # Pack index v2 (mmap + binary search)
├── pack_objects.zig       # Pack writer with delta compression
├── pack_bitmap.zig        # EWAH bitmap reader
├── commit_graph.zig       # Commit-graph reader/writer
├── delta.zig              # Git delta format
│
│ ── Index & Working Tree ──
├── index.zig              # Git index (DIRC format, v2/v3/v4)
├── index_ext.zig          # Extensions (TREE, REUC, EOIE, IEOT)
├── ignore.zig             # .gitignore patterns
├── attributes.zig         # .gitattributes
│
│ ── Refs ──
├── ref.zig                # Ref CRUD (loose + packed-refs)
├── refspec.zig            # Refspec parsing and matching
├── reflog.zig             # Reflog read/write
│
│ ── Diff Engine ──
├── diff.zig               # Myers diff + unified output
├── tree_diff.zig          # Recursive tree comparison
├── patience_diff.zig      # Patience/histogram diff algorithms
├── word_diff.zig          # Word-level diff
├── diff_rename.zig        # Rename/copy detection
├── diff_stat.zig          # --stat/--numstat/--dirstat
│
│ ── Merge Engine ──
├── merge.zig              # Three-way merge + conflict markers
├── merge_strategies.zig   # ours/theirs/recursive strategies
├── merge_base.zig         # LCA finding in commit DAG
│
│ ── Network ──
├── transport.zig          # Transport abstraction
├── smart_http.zig         # Git smart HTTP protocol (via curl)
├── smart_ssh.zig          # SSH transport (via ssh subprocess)
├── http_transport.zig     # HTTP client helpers
├── ssh_transport.zig      # SSH connection helpers
├── pkt_line.zig           # Git pkt-line protocol
├── protocol_v2.zig        # Git protocol v2
├── capabilities.zig       # Protocol capability negotiation
├── url.zig                # Git URL parsing
│
│ ── Infrastructure ──
├── config.zig             # INI-like config parser/writer
├── config_ext.zig         # --global/--system, includes
├── hooks.zig              # Git hooks execution
├── mailmap.zig            # .mailmap support
├── color.zig              # ANSI color management
├── pager.zig              # Pager (less) integration
├── editor.zig             # Editor launch for commit messages
├── alias.zig              # Git alias support
├── progress.zig           # Progress bars
├── trace.zig              # GIT_TRACE debug system
├── pathspec.zig           # Advanced pathspec matching
│
└── [40+ command files]     # add, commit, log, checkout, merge, etc.
```

## Why Zig

| Advantage | Effect on git |
|-----------|--------------|
| **C ABI compatible** | Links libz directly. No wrapper overhead |
| **Cross-compilation** | Eliminates 34K-line `compat/` platform layer |
| **Comptime** | Compile-time optimized pack format parsing |
| **Memory safety** | Prevents buffer overflows (git's #1 CVE category) |
| **Single-file build** | `build.zig` replaces autoconf + make + cmake |
| **Explicit allocators** | No hidden allocations, catches leaks in debug builds |
| **Error unions** | `try` replaces thousands of `if (ret < 0) goto cleanup` patterns |

## Comparison

| Implementation | Language | LOC | CLI | Network | Status |
|----------------|----------|-----|-----|---------|--------|
| [git](https://github.com/git/git) | C | 434,286 | Full | Full | Reference |
| [gitoxide](https://github.com/GitoxideLabs/gitoxide) | Rust | ~250,000 | Partial | Partial | Active |
| [JGit](https://eclipse.dev/jgit/) | Java | ~300,000 | Full | Full | Mature |
| [go-git](https://github.com/go-git/go-git) | Go | ~80,000 | No | Yes | Library |
| [libgit2](https://github.com/libgit2/libgit2) | C | ~200,000 | No | Yes | Library |
| **zig-git** | **Zig** | **63,113** | **65+ cmds** | **HTTPS/SSH/local** | **Functional** |

## Known Limitations

- **HTTPS push** works but is not battle-tested with all Git hosting providers
- **Complex merges** (criss-cross, rename conflicts) may differ from git's resolution
- **Performance** not yet optimized (no parallel decompression, no mmap for pack reads)
- **Platform** tested on macOS ARM64. Linux should work. Windows untested
- **Interactive rebase** (`-i`) has basic implementation but no full TUI

## Building

```bash
# Build
zig build

# Run
./zig-out/bin/zig-git <command>

# Run tests
zig build test

# Build optimized release
zig build -Doptimize=ReleaseFast
```

## License

MIT

## Roadmap

See [GIT_ZIG_ROADMAP.md](./GIT_ZIG_ROADMAP.md) for the original LOC-based migration analysis.

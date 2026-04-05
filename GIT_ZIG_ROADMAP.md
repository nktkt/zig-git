# Git → Zig 移植ロードマップ

## プロジェクト概要

git (C実装) を Zig に段階的に移植する計画。
LOC (Lines of Code) を基準にフェーズを分割し、各フェーズで独立して動作可能な成果物を目指す。

## 現行コードベース規模

| 言語 | ファイル数 | LOC | 備考 |
|------|-----------|-----|------|
| C (.c) | 629 | 383,211 | コア実装 |
| C (.h) | 338 | 51,075 | ヘッダ |
| Shell (.sh) | 1,279 | 330,746 | テスト1,208件 + スクリプト |
| Perl (.perl/.pm) | 47 | 33,236 | git-svn, git-send-email 等 |
| Python (.py) | 3 | 5,035 | 補助ツール |
| Documentation | - | 140,023 | マニュアル |
| **C合計** | **967** | **434,286** | **移植対象の本体** |

## 機能別LOC内訳 (C)

| 機能グループ | LOC | 比率 | 主要ファイル |
|-------------|-----|------|-------------|
| CLI/Porcelain (builtin/) | 94,541 | 21.8% | pack-objects(5302), fast-import(3997), submodule--helper(3836), gc(3535), fetch(2883) |
| Object Storage | 13,774 | 3.2% | object-file, packfile, pack-bitmap, commit-graph |
| Refs | 21,162 | 4.9% | refs.c(3553), refs/*, reftable/* |
| Diff/Merge | 17,765 | 4.1% | diff(7576), merge-ort(5602), xdiff/* |
| Index | 11,322 | 2.6% | read-cache(4065), unpack-trees(3071), dir(4186) |
| Network | 10,551 | 2.4% | remote(2965), http(2959), fetch-pack(2297) |
| Config/Setup | 7,178 | 1.7% | config(3594), setup(2860) |
| Compat/Platform | 6,862 + 33,971 | 9.4% | compat/*(OS抽象化層) |
| その他コア | ~123,000 | ~28% | sequencer, apply, blame, grep, convert 等 |
| トップレベルヘッダ | 51,075 | 11.8% | データ構造定義 |
| テスト (t/*.c) | 23,584 | 5.4% | C単体テスト |

---

## フェーズ構成

### Phase 0: 基盤 (Foundation)
**目標LOC: ~15,000 Zig (新規)**
**期間目安: 2-3ヶ月**
**依存: なし**

Zigプロジェクトの骨格とgitの基本データ構造を構築する。

| タスク | 対応元LOC | 出力 |
|--------|----------|------|
| ビルドシステム (build.zig) | - | Zigネイティブビルド |
| SHA-1 / SHA-256 ハッシュ | 2,445 + 339 (sha1dc/, sha256/) | `hash.zig` |
| zlib圧縮/展開 | compat内の一部 | Zig標準ライブラリ利用 or Cリンク |
| 基本型定義 (object_id, strbuf相当) | ~3,000 (ヘッダ群) | `types.zig` |
| メモリアロケータ抽象化 | 散在 | Zig allocator interface |
| エラーハンドリングパターン | 散在 | Zig error union 設計 |

**マイルストーン:** SHA-256ハッシュのバイナリが動く。ベンチマークでC版と比較可能。

---

### Phase 1: Object Layer (オブジェクト層)
**目標LOC: ~20,000 Zig**
**移植元LOC: ~13,774 + ヘッダ**
**期間目安: 3-4ヶ月**
**依存: Phase 0**

gitの心臓部。blob/tree/commit/tagオブジェクトの読み書き。

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Loose object 読み書き | object-file.c | 2,275 |
| Object name 解決 | object-name.c | 2,188 |
| Pack file 読み込み | packfile.c | 2,691 |
| Pack index | midx-write.c, midx.c | ~3,500 |
| Pack bitmap | pack-bitmap.c | 3,420 |
| Commit graph | commit-graph.c | 2,932 |
| Object iteration | object.c, tag.c, tree.c, blob.c | ~2,500 |

**マイルストーン:** `zig-git cat-file -p <sha>` が動く。既存リポジトリのオブジェクトを読める。

---

### Phase 2: Index & Working Tree (インデックス層)
**目標LOC: ~15,000 Zig**
**移植元LOC: ~11,322**
**期間目安: 2-3ヶ月**
**依存: Phase 1**

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Index (staging area) 読み書き | read-cache.c | 4,065 |
| Tree展開/比較 | unpack-trees.c | 3,071 |
| ディレクトリ走査/除外パターン | dir.c | 4,186 |

**マイルストーン:** `zig-git status` が動く（差分表示まで）。

---

### Phase 3: Refs (参照管理)
**目標LOC: ~22,000 Zig**
**移植元LOC: ~21,162**
**期間目安: 3-4ヶ月**
**依存: Phase 1**

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Refs抽象API | refs.c | 3,553 |
| Files backend | refs/files-backend.c | ~3,500 |
| Packed refs | refs/packed-backend.c | ~2,500 |
| Reftable backend | reftable/*.c | 9,097 |
| Reflog | refs/debug.c, iterator | ~2,500 |

**マイルストーン:** `zig-git branch`, `zig-git tag` が動く。

---

### Phase 4: Diff & Merge (差分/マージ)
**目標LOC: ~20,000 Zig**
**移植元LOC: ~17,765**
**期間目安: 3-4ヶ月**
**依存: Phase 1, 2**

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Diff コア | diff.c | 7,576 |
| Diff ライブラリ | diff-lib.c, diffcore-*.c | ~3,000 |
| xdiff (Myers/patience/histogram) | xdiff/*.c | 4,363 |
| Merge ORT | merge-ort.c | 5,602 |

**マイルストーン:** `zig-git diff`, `zig-git merge` が動く。

---

### Phase 5: Config & Setup (設定層)
**目標LOC: ~8,000 Zig**
**移植元LOC: ~7,178**
**期間目安: 1-2ヶ月**
**依存: Phase 0**

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Config パーサー/ライター | config.c | 3,594 |
| リポジトリ検出/初期化 | setup.c | 2,860 |
| 環境変数 | environment.c | 724 |

**マイルストーン:** `zig-git init`, `zig-git config` が動く。

---

### Phase 6: Network (ネットワーク層)
**目標LOC: ~12,000 Zig**
**移植元LOC: ~10,551**
**期間目安: 2-3ヶ月**
**依存: Phase 1, 3**

| タスク | 対応元ファイル | LOC |
|--------|--------------|-----|
| Remote管理 | remote.c | 2,965 |
| HTTP transport | http.c | 2,959 |
| Pack protocol (fetch) | fetch-pack.c | 2,297 |
| Pack protocol (push) | send-pack.c | ~1,500 |
| Transport抽象化 | transport.c, connect.c | ~2,000 |

**マイルストーン:** `zig-git clone`, `zig-git fetch`, `zig-git push` が動く。

---

### Phase 7: Porcelain コマンド (前半)
**目標LOC: ~35,000 Zig**
**移植元LOC: ~47,000 (builtin/ の上位半分)**
**期間目安: 4-6ヶ月**
**依存: Phase 1-6**

高頻度コマンドを優先。

| 優先度 | コマンド | 対応元ファイル | LOC |
|--------|---------|--------------|-----|
| P0 | add, commit, status | builtin/add.c, commit.c, wt-status.c | ~5,700 |
| P0 | log, show | builtin/log.c, pretty.c, revision.c | ~9,300 |
| P0 | checkout, switch | builtin/checkout.c | 2,162 |
| P0 | branch | builtin/branch.c | ~800 |
| P1 | clone, fetch, push | builtin/clone.c, fetch.c, push.c | ~5,500 |
| P1 | merge, rebase | builtin/merge.c, rebase.c | ~3,800 |
| P1 | stash | builtin/stash.c | 2,445 |
| P1 | cherry-pick, revert | sequencer.c | 6,884 |
| P1 | am | builtin/am.c | 2,560 |

**マイルストーン:** 日常的なgitワークフロー（clone→branch→edit→commit→push）が完走する。

---

### Phase 8: Porcelain コマンド (後半)
**目標LOC: ~30,000 Zig**
**移植元LOC: ~47,000 (builtin/ の残り)**
**期間目安: 4-6ヶ月**
**依存: Phase 7**

| 優先度 | コマンド | LOC |
|--------|---------|-----|
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
| P3 | その他全builtin | ~17,000 |

**マイルストーン:** `git test suite` の90%以上がパスする。

---

### Phase 9: Platform Compat (プラットフォーム層)
**目標LOC: ~10,000 Zig (大幅削減)**
**移植元LOC: ~33,971 (compat/)**
**期間目安: 2-3ヶ月**
**依存: Phase 0-8**

Zigのクロスコンパイル能力により、C版の compat/ の大部分は不要になる。

| タスク | 備考 |
|--------|------|
| Windows対応 | Zigの std.fs, std.os が抽象化済み。compat/mingw.c (5000行+) の大半が不要 |
| macOS対応 | iconv, regex 等のみ |
| Linux対応 | 最小限 |

**マイルストーン:** Linux/macOS/Windows で全テストがパスする。

---

### Phase 10: テストスイート移植
**目標LOC: ~50,000 Zig テスト**
**移植元LOC: ~314,672 (shell) + 23,584 (C)**
**期間目安: 並行して全フェーズで実施**

| 方針 | 詳細 |
|------|------|
| 段階的移植 | 各Phase完了時に対応するシェルテストをZig testに変換 |
| 互換レイヤー | 初期は既存シェルテストをそのまま使う（バイナリ名のみ差し替え） |
| Zigネイティブテスト | `zig test` で内部API単体テスト |

---

## 全体タイムライン

```
Phase 0: 基盤              ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░  [~15K Zig]
Phase 5: Config/Setup        ███░░░░░░░░░░░░░░░░░░░░░░░░░░░░  [~8K Zig]
Phase 1: Object Layer          ██████░░░░░░░░░░░░░░░░░░░░░░░░  [~20K Zig]
Phase 2: Index/Tree               █████░░░░░░░░░░░░░░░░░░░░░░  [~15K Zig]
Phase 3: Refs                     ██████░░░░░░░░░░░░░░░░░░░░░░  [~22K Zig]
Phase 4: Diff/Merge                  ██████░░░░░░░░░░░░░░░░░░░  [~20K Zig]
Phase 6: Network                        █████░░░░░░░░░░░░░░░░░  [~12K Zig]
Phase 7: Porcelain (前半)                   █████████░░░░░░░░░░  [~35K Zig]
Phase 8: Porcelain (後半)                            █████████░  [~30K Zig]
Phase 9: Platform Compat                                ██████░  [~10K Zig]
Phase 10: テスト              ─────────────────────────────────  [並行]
                             M1  M3  M6  M9  M12 M15 M18 M21 M24
```

## LOCサマリー

| 区分 | C (元) | Zig (推定) | 比率 | 理由 |
|------|--------|-----------|------|------|
| コア実装 | 434,286 | ~187,000 | 0.43x | Zigの表現力、compat層削減、ヘッダ不要 |
| テスト | 338,256 | ~50,000 (Zig) + 既存shell | - | シェルテスト再利用 |
| **合計移植対象** | **434,286** | **~187,000** | - | - |

### なぜ Zig LOC が減るか

1. **ヘッダ不要** (-51,075): Zigはモジュールシステムで宣言と実装が一体
2. **compat/大幅削減** (-24,000): Zig std が OS差異を吸収
3. **strbuf/string系の簡素化** (-推定10,000): Zigスライスとアロケータで自然に表現
4. **マクロ展開の削減** (-推定5,000): Zigの comptime で型安全に
5. **エラーハンドリングの簡素化**: `if (ret < 0) goto cleanup` パターンが `try` 一語に

## Zigを選ぶ利点 (git移植において)

| 利点 | gitでの具体的効果 |
|------|------------------|
| C ABIとの完全互換 | 既存のlibz, libcurl, openssl をそのままリンク可能。段階移行が容易 |
| クロスコンパイル内蔵 | compat/ 33,971行の大部分が不要に |
| comptime | pack formatのパース、ハッシュ選択をコンパイル時に最適化 |
| 安全性 | バッファオーバーフロー (gitのCVE歴の主因) を型で防止 |
| ビルド速度 | build.zig で make/autoconf/cmake 不要 |
| テスト内蔵 | `zig test` でC時代のテストインフラが不要 |

## リスクと対策

| リスク | 影響 | 対策 |
|--------|------|------|
| Zig自体の安定性 (まだ pre-1.0) | ビルド破壊 | Zigバージョン固定、CI で nightly と stable 両方テスト |
| libcurl/openssl依存 | ネットワーク層の移植に影響 | Phase 6 まではCライブラリリンク。将来的に zig-http に置換検討 |
| git wire protocol の互換性 | fetch/push の不具合 | 既存テストスイートをそのまま実行して検証 |
| 1人での規模限界 | Phase 7以降が巨大 | Phase 6完了でMVP (最小限使えるgit)。以降はコミュニティ参加を募る |

## 参考: 既存のgit代替実装

| プロジェクト | 言語 | LOC | 互換性 | 備考 |
|-------------|------|-----|--------|------|
| libgit2 | C | ~200K | ライブラリのみ (CLIなし) | GitHub Desktop等が使用 |
| gitoxide (gix) | Rust | ~250K | CLI + ライブラリ | 最も完成度が高い代替。参考になる |
| go-git | Go | ~80K | ライブラリ中心 | pure Go実装 |
| JGit | Java | ~300K | Eclipse系 | Java実装 |
| **本プロジェクト** | **Zig** | **~187K (推定)** | **CLI互換目標** | - |

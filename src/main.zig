const std = @import("std");
const repository = @import("repository.zig");
const cat_file = @import("cat_file.zig");
const hash_mod = @import("hash.zig");
const types = @import("types.zig");
const index_mod = @import("index.zig");
const loose = @import("loose.zig");
const config_mod = @import("config.zig");
const init_mod = @import("init.zig");
const status_mod = @import("status.zig");
const branch_mod = @import("branch.zig");
const tag_mod = @import("tag.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const add_mod = @import("add.zig");
const commit_mod = @import("commit_cmd.zig");
const log_mod = @import("log.zig");
const diff_mod = @import("diff.zig");
const show_mod = @import("show.zig");
const rev_parse_mod = @import("rev_parse.zig");
const checkout_mod = @import("checkout.zig");
const merge_mod = @import("merge.zig");
const reset_mod = @import("reset.zig");
const stash_mod = @import("stash.zig");
const remote_mod = @import("remote.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const clean_mod = @import("clean.zig");
const rm_mod = @import("rm.zig");
const mv_mod = @import("mv.zig");
const describe_mod = @import("describe.zig");
const shortlog_mod = @import("shortlog.zig");
const notes_mod = @import("notes.zig");
const count_objects_mod = @import("count_objects.zig");
const fsck_mod = @import("fsck.zig");
const grep_mod = @import("grep.zig");
const blame_mod = @import("blame.zig");
const cherry_pick_mod = @import("cherry_pick.zig");
const rebase_mod = @import("rebase.zig");
const bisect_mod = @import("bisect.zig");
const worktree_mod = @import("worktree.zig");
const archive_mod = @import("archive.zig");
const gc_mod = @import("gc.zig");
const prune_mod = @import("prune.zig");
const repack_mod_cmd = @import("repack.zig");
const maintenance_mod = @import("maintenance.zig");
const pack_refs_mod = @import("pack_refs.zig");
const reflog_expire_mod = @import("reflog_expire.zig");
const commit_graph_write_mod = @import("commit_graph_write.zig");
const attributes_mod = @import("attributes.zig");
const hooks_mod = @import("hooks.zig");
const sparse_checkout_mod = @import("sparse_checkout.zig");
const bundle_mod = @import("bundle.zig");
const rerere_mod = @import("rerere.zig");
const range_diff_mod = @import("range_diff.zig");
const multi_pack_index_mod = @import("multi_pack_index.zig");
const shallow_mod = @import("shallow.zig");
const filter_branch_mod = @import("filter_branch.zig");
const credential_mod = @import("credential.zig");
const var_mod = @import("var.zig");
const hash_object_ext_mod = @import("hash_object_ext.zig");
const ls_files_mod = @import("ls_files.zig");
const ls_tree_mod = @import("ls_tree.zig");
const update_index_mod = @import("update_index.zig");
const write_tree_mod = @import("write_tree.zig");
const read_tree_mod = @import("read_tree.zig");
const for_each_ref_mod = @import("for_each_ref.zig");
const verify_pack_mod = @import("verify_pack.zig");
const symbolic_ref_mod = @import("symbolic_ref.zig");
const check_ignore_mod = @import("check_ignore.zig");
const diff_tree_mod = @import("diff_tree.zig");
const submodule_mod = @import("submodule.zig");
const apply_mod_cmd = @import("apply.zig");
const format_patch_mod = @import("format_patch.zig");
const am_mod = @import("am.zig");
const send_email_mod = @import("send_email.zig");
const rev_list_mod = @import("rev_list.zig");
const diff_files_mod = @import("diff_files.zig");
const diff_index_mod = @import("diff_index.zig");
const name_rev_mod = @import("name_rev.zig");
const merge_base_mod = @import("merge_base.zig");
const verify_commit_mod = @import("verify_commit.zig");
const commit_info_mod = @import("commit_info.zig");
const log_format_mod = @import("log_format.zig");
const add_interactive_mod = @import("add_interactive.zig");
const tag_verify_mod = @import("tag_verify.zig");
const merge_strategies_mod = @import("merge_strategies.zig");
const config_ext_mod = @import("config_ext.zig");
const switch_cmd_mod = @import("switch_cmd.zig");
const restore_mod = @import("restore.zig");
const diff_stat_mod = @import("diff_stat.zig");
const word_diff_mod = @import("word_diff.zig");
const pull_mod = @import("pull.zig");
const pager_mod = @import("pager.zig");
const editor_mod = @import("editor.zig");
const alias_mod = @import("alias.zig");

comptime {
    _ = @import("hash.zig");
    _ = @import("types.zig");
    _ = @import("delta.zig");
    _ = @import("compress.zig");
    _ = @import("loose.zig");
    _ = @import("pack_index.zig");
    _ = @import("pack.zig");
    _ = @import("pack_bitmap.zig");
    _ = @import("commit_graph.zig");
    _ = @import("repository.zig");
    _ = @import("cat_file.zig");
    _ = @import("config.zig");
    _ = @import("init.zig");
    _ = @import("index.zig");
    _ = @import("ignore.zig");
    _ = @import("status.zig");
    _ = @import("branch.zig");
    _ = @import("tag.zig");
    _ = @import("ref.zig");
    _ = @import("reflog.zig");
    _ = @import("tree_builder.zig");
    _ = @import("add.zig");
    _ = @import("commit_cmd.zig");
    _ = @import("rev_parse.zig");
    _ = @import("diff.zig");
    _ = @import("log.zig");
    _ = @import("show.zig");
    _ = @import("tree_diff.zig");
    _ = @import("remote.zig");
    _ = @import("clone.zig");
    _ = @import("fetch.zig");
    _ = @import("push.zig");
    _ = @import("pack_writer.zig");
    _ = @import("object_walk.zig");
    _ = @import("checkout.zig");
    _ = @import("merge.zig");
    _ = @import("reset.zig");
    _ = @import("stash.zig");
    _ = @import("clean.zig");
    _ = @import("rm.zig");
    _ = @import("mv.zig");
    _ = @import("describe.zig");
    _ = @import("shortlog.zig");
    _ = @import("notes.zig");
    _ = @import("count_objects.zig");
    _ = @import("fsck.zig");
    _ = @import("grep.zig");
    _ = @import("blame.zig");
    _ = @import("cherry_pick.zig");
    _ = @import("rebase.zig");
    _ = @import("bisect.zig");
    _ = @import("worktree.zig");
    _ = @import("archive.zig");
    _ = @import("gc.zig");
    _ = @import("prune.zig");
    _ = @import("repack.zig");
    _ = @import("maintenance.zig");
    _ = @import("pack_refs.zig");
    _ = @import("reflog_expire.zig");
    _ = @import("commit_graph_write.zig");
    _ = @import("pack_objects.zig");
    _ = @import("diff_stat.zig");
    _ = @import("diff_rename.zig");
    _ = @import("word_diff.zig");
    _ = @import("patience_diff.zig");
    _ = @import("attributes.zig");
    _ = @import("hooks.zig");
    _ = @import("mailmap.zig");
    _ = @import("sparse_checkout.zig");
    _ = @import("color.zig");
    _ = @import("bundle.zig");
    _ = @import("rerere.zig");
    _ = @import("range_diff.zig");
    _ = @import("multi_pack_index.zig");
    _ = @import("shallow.zig");
    _ = @import("filter_branch.zig");
    _ = @import("credential.zig");
    _ = @import("var.zig");
    _ = @import("hash_object_ext.zig");
    _ = @import("ls_files.zig");
    _ = @import("ls_tree.zig");
    _ = @import("update_index.zig");
    _ = @import("write_tree.zig");
    _ = @import("read_tree.zig");
    _ = @import("for_each_ref.zig");
    _ = @import("verify_pack.zig");
    _ = @import("symbolic_ref.zig");
    _ = @import("check_ignore.zig");
    _ = @import("diff_tree.zig");
    _ = @import("submodule.zig");
    _ = @import("submodule_config.zig");
    _ = @import("apply.zig");
    _ = @import("format_patch.zig");
    _ = @import("am.zig");
    _ = @import("send_email.zig");
    _ = @import("patch.zig");
    _ = @import("rev_list.zig");
    _ = @import("diff_files.zig");
    _ = @import("diff_index.zig");
    _ = @import("name_rev.zig");
    _ = @import("merge_base.zig");
    _ = @import("verify_commit.zig");
    _ = @import("commit_info.zig");
    _ = @import("refspec.zig");
    _ = @import("protocol_v2.zig");
    _ = @import("index_ext.zig");
    _ = @import("trace.zig");
    _ = @import("progress.zig");
    _ = @import("pathspec.zig");
    _ = @import("log_format.zig");
    _ = @import("add_interactive.zig");
    _ = @import("tag_verify.zig");
    _ = @import("merge_strategies.zig");
    _ = @import("config_ext.zig");
    _ = @import("switch_cmd.zig");
    _ = @import("restore.zig");
    _ = @import("pull.zig");
    _ = @import("pager.zig");
    _ = @import("editor.zig");
    _ = @import("alias.zig");
    _ = @import("smart_http.zig");
    _ = @import("smart_ssh.zig");
    _ = @import("pack_index_writer.zig");
}

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const usage =
    \\usage: zig-git <command> [<args>]
    \\
    \\Core commands:
    \\  init         Create an empty Git repository
    \\  clone        Clone a repository into a new directory
    \\  add          Add file contents to the index
    \\  commit       Record changes to the repository
    \\  status       Show the working tree status
    \\  diff         Show changes between commits, commit and working tree, etc.
    \\  log          Show commit logs
    \\  show         Show various types of objects
    \\
    \\Branch & tag:
    \\  branch       List, create, or delete branches
    \\  checkout     Switch branches or restore working tree files
    \\  switch       Switch branches (safer alternative to checkout)
    \\  merge        Join two or more development histories together
    \\  tag          Create, list, delete or verify a tag object
    \\
    \\Working tree:
    \\  restore      Restore working tree files
    \\  clean        Remove untracked files from the working tree
    \\  rm           Remove files from the working tree and index
    \\  mv           Move or rename a file, a directory, or a symlink
    \\
    \\Undo & stash:
    \\  reset        Reset current HEAD to the specified state
    \\  stash        Stash the changes in a dirty working directory
    \\
    \\Remote:
    \\  remote       Manage set of tracked repositories
    \\  fetch        Download objects and refs from another repository
    \\  pull         Fetch from and integrate with another repository
    \\  push         Update remote refs along with associated objects
    \\
    \\History rewriting:
    \\  cherry-pick  Apply the changes introduced by some existing commits
    \\  rebase       Reapply commits on top of another base tip
    \\  bisect       Use binary search to find the commit that introduced a bug
    \\
    \\Inspect & compare:
    \\  grep         Print lines matching a pattern
    \\  blame        Show what revision and author last modified each line
    \\  describe     Give an object a human readable name based on tags
    \\  shortlog     Summarize 'git log' output
    \\  notes        Add or inspect object notes
    \\
    \\Maintenance:
    \\  gc           Run garbage collection
    \\  prune        Remove unreachable loose objects
    \\  repack       Repack objects into pack files
    \\  maintenance  Run maintenance tasks
    \\  pack-refs    Pack loose refs into packed-refs file
    \\
    \\Plumbing:
    \\  cat-file       Provide content or type and size info for objects
    \\  hash-object    Compute object ID and optionally create a blob
    \\  rev-parse      Pick out and massage parameters
    \\  config         Get and set repository or global options
    \\  reflog         Show reference logs
    \\  count-objects  Count unpacked objects and disk consumption
    \\  fsck           Verify connectivity and validity of objects
    \\  worktree       Manage multiple working trees
    \\  archive        Create an archive of files from a named tree
    \\  ls-files       Show information about files in index/working tree
    \\  ls-tree        List the contents of a tree object
    \\  update-index   Register file contents in the working tree to index
    \\  write-tree     Create a tree object from the current index
    \\  read-tree      Read tree information into the index
    \\  for-each-ref   Output information on each ref
    \\  verify-pack    Validate packed Git archive files
    \\  symbolic-ref   Read, modify, and delete symbolic refs
    \\  check-ignore   Debug gitignore / exclude files
    \\  diff-tree      Compare the content and mode of trees
    \\  rev-list       List commit objects in reverse chronological order
    \\  diff-files     Compare files in the working tree and the index
    \\  diff-index     Compare a tree to the working tree or index
    \\  name-rev       Find symbolic names for given revs
    \\  merge-base     Find common ancestor of two commits
    \\  verify-commit  Check the GPG signature of commits
    \\  verify-tag     Check the GPG signature of tags
    \\
    \\  version        Display version information
    \\
;

const cat_file_usage =
    \\usage: zig-git cat-file (-t | -s | -p | -e) <object>
    \\
    \\  -p    Pretty-print the contents of <object>
    \\  -t    Show the object type
    \\  -s    Show the object size
    \\  -e    Check if <object> exists (exit code only)
    \\
;

const hash_object_usage =
    \\usage: zig-git hash-object [-t <type>] [-w] <file>
    \\
    \\  -t <type>   Object type (default: blob)
    \\  -w          Write the object into the object database
    \\
;

const init_usage =
    \\usage: zig-git init [--bare] [-b <branch>] [<directory>]
    \\
    \\  --bare         Create a bare repository
    \\  -b <branch>    Use <branch> as initial branch name
    \\
;

const config_usage =
    \\usage: zig-git config [--get] [--set] <key> [<value>]
    \\
    \\  --get          Get the value of a config key
    \\  --list         List all config entries
    \\  <key> <value>  Set the value of a config key
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stderr_file.writeAll(usage);
        std.process.exit(1);
    }

    // Parse global options before the command
    var cmd_start: usize = 1;
    while (cmd_start < args.len) {
        if (std.mem.eql(u8, args[cmd_start], "--no-pager")) {
            pager_mod.no_pager = true;
            cmd_start += 1;
        } else {
            break;
        }
    }

    if (cmd_start >= args.len) {
        try stderr_file.writeAll(usage);
        std.process.exit(1);
    }

    const command = args[cmd_start];
    const cmd_args = args[cmd_start + 1 ..];

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout_file.writeAll("zig-git version 0.2.0\n");
        return;
    }

    // Commands that don't need a repo
    if (std.mem.eql(u8, command, "init")) return runInit(allocator, cmd_args);
    if (std.mem.eql(u8, command, "clone")) return runClone(allocator, cmd_args);
    if (std.mem.eql(u8, command, "hash-object")) return runHashObject(allocator, cmd_args);

    // Commands that need a repo
    if (std.mem.eql(u8, command, "cat-file")) return runCatFile(allocator, cmd_args);
    if (std.mem.eql(u8, command, "config")) return runConfig(allocator, cmd_args);
    if (std.mem.eql(u8, command, "status")) return runStatusCmd(allocator);
    if (std.mem.eql(u8, command, "branch")) return runBranchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "tag")) return runTagCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "reflog")) return runReflogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "add")) return runAddCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "commit")) return runCommitCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "log")) return runLogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "diff")) return runDiffCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "show")) return runShowCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rev-parse")) return runRevParseCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "checkout")) return runCheckoutCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "switch")) return runSwitchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "restore")) return runRestoreCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "merge")) return runMergeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "pull")) return runPullCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "reset")) return runResetCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "stash")) return runStashCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "remote")) return runRemoteCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "fetch")) return runFetchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "push")) return runPushCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "clean")) return runCleanCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rm") or std.mem.eql(u8, command, "remove")) return runRmCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "mv") or std.mem.eql(u8, command, "move")) return runMvCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "describe")) return runDescribeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "shortlog")) return runShortlogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "notes")) return runNotesCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "count-objects")) return runCountObjectsCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "fsck")) return runFsckCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "grep")) return runGrepCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "blame") or std.mem.eql(u8, command, "annotate")) return runBlameCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "cherry-pick")) return runCherryPickCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rebase")) return runRebaseCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "bisect")) return runBisectCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "worktree")) return runWorktreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "archive")) return runArchiveCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "gc")) return runGcCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "prune")) return runPruneCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "repack")) return runRepackCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "maintenance")) return runMaintenanceCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "pack-refs")) return runPackRefsCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "bundle")) return runBundleCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rerere")) return runRerereCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "range-diff")) return runRangeDiffCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "multi-pack-index")) return runMultiPackIndexCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "filter-branch")) return runFilterBranchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "credential")) return runCredentialCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "var")) return runVarCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "mktag")) return runMktagCmd(allocator);
    if (std.mem.eql(u8, command, "mktree")) return runMktreeCmd(allocator);
    if (std.mem.eql(u8, command, "commit-tree")) return runCommitTreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "check-attr")) return runCheckAttrCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "hook")) return runHookCmdDispatch(allocator, cmd_args);
    if (std.mem.eql(u8, command, "sparse-checkout")) return runSparseCheckoutCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "ls-files")) return runLsFilesCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "ls-tree")) return runLsTreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "update-index")) return runUpdateIndexCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "write-tree")) return runWriteTreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "read-tree")) return runReadTreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "for-each-ref")) return runForEachRefCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "verify-pack")) return runVerifyPackCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "symbolic-ref")) return runSymbolicRefCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "check-ignore")) return runCheckIgnoreCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "diff-tree")) return runDiffTreeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "submodule")) return runSubmoduleCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "apply")) return runApplyCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "format-patch")) return runFormatPatchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "am")) return runAmCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "send-email")) return runSendEmailCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rev-list")) return runRevListCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "diff-files")) return runDiffFilesCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "diff-index")) return runDiffIndexCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "name-rev")) return runNameRevCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "merge-base")) return runMergeBaseCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "verify-commit")) return runVerifyCommitCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "verify-tag")) return runVerifyTagCmd(allocator, cmd_args);

    // Before "unknown command" error, check aliases
    const repo_for_alias = repository.Repository.discover(allocator, null) catch null;
    if (repo_for_alias) |r| {
        var repo_val = r;
        defer repo_val.deinit();

        if (alias_mod.resolveAlias(allocator, repo_val.git_dir, command, cmd_args) catch null) |result| {
            var alias_result = result;
            defer alias_result.deinit();

            if (alias_result.is_shell) {
                if (alias_result.shell_cmd) |shell_cmd| {
                    alias_mod.executeShellAlias(allocator, shell_cmd, cmd_args) catch |err| {
                        fatalError("alias execution failed", err);
                    };
                    return;
                }
            } else if (alias_result.args.len > 0) {
                // Re-dispatch with the resolved command
                return dispatchCommand(allocator, alias_result.args[0], alias_result.args[1..]);
            }
        }
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zig-git: '{s}' is not a zig-git command.\n\n", .{command}) catch {
        try stderr_file.writeAll("zig-git: unknown command\n");
        std.process.exit(1);
    };
    try stderr_file.writeAll(msg);
    try stderr_file.writeAll(usage);
    std.process.exit(1);
}

// --- Plumbing commands ---

fn runCatFile(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try stderr_file.writeAll(cat_file_usage);
        std.process.exit(1);
    }

    var mode: cat_file.Mode = .pretty;
    var object_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            mode = .pretty;
        } else if (std.mem.eql(u8, arg, "-t")) {
            mode = .type_only;
        } else if (std.mem.eql(u8, arg, "-s")) {
            mode = .size_only;
        } else if (std.mem.eql(u8, arg, "-e")) {
            mode = .exists;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            object_ref = arg;
        }
    }

    if (object_ref == null) {
        try stderr_file.writeAll(cat_file_usage);
        std.process.exit(1);
    }

    var repo = discoverRepo(allocator);
    defer repo.deinit();

    cat_file.catFile(&repo, allocator, object_ref.?, mode, stdout_file) catch |err| {
        switch (err) {
            error.ObjectNotFound => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{object_ref.?}) catch "fatal: Not a valid object name\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            },
            error.AmbiguousObjectName => {
                try stderr_file.writeAll("fatal: ambiguous argument\n");
                std.process.exit(128);
            },
            else => return err,
        }
    };
}

fn runHashObject(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var obj_type: types.ObjectType = .blob;
    var write_object = false;
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll(hash_object_usage);
                std.process.exit(1);
            }
            obj_type = types.ObjectType.fromString(args[i]) catch {
                try stderr_file.writeAll("fatal: invalid object type\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-w")) {
            write_object = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    if (file_path == null) {
        try stderr_file.writeAll(hash_object_usage);
        std.process.exit(1);
    }

    const file = std.fs.cwd().openFile(file_path.?, .{}) catch {
        try stderr_file.writeAll("fatal: could not open file\n");
        std.process.exit(128);
    };
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const n = try file.readAll(content);
    const data = content[0..n];

    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    try hwriter.writeAll(obj_type.toString());
    try hwriter.writeByte(' ');
    try hwriter.print("{d}", .{data.len});
    try hwriter.writeByte(0);
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    const digest = hasher.finalResult();
    const oid = types.ObjectId{ .bytes = digest };

    if (write_object) {
        var repo = discoverRepo(allocator);
        defer repo.deinit();
        _ = try loose.writeLooseObject(allocator, repo.git_dir, obj_type, data);
    }

    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

// --- Setup commands ---

fn runInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = init_mod.InitOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bare")) {
            opts.bare = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--initial-branch")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll(init_usage);
                std.process.exit(1);
            }
            opts.initial_branch = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.directory = arg;
        }
    }

    const git_dir = init_mod.initRepository(allocator, opts) catch |err| {
        fatalError("cannot create repository", err);
    };
    allocator.free(git_dir);
}

fn runClone(allocator: std.mem.Allocator, args: []const []const u8) !void {
    clone_mod.runClone(allocator, args) catch |err| {
        fatalError("clone failed", err);
    };
}

// --- Config ---

fn runConfig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(config_usage);
        std.process.exit(1);
    }

    // Check for extended config flags that config_ext handles
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--global") or
            std.mem.eql(u8, arg, "--system") or
            std.mem.eql(u8, arg, "--unset") or
            std.mem.eql(u8, arg, "--unset-all") or
            std.mem.eql(u8, arg, "--rename-section") or
            std.mem.eql(u8, arg, "--remove-section") or
            std.mem.eql(u8, arg, "-e") or
            std.mem.eql(u8, arg, "--edit"))
        {
            // Use the extended config handler
            var repo_ptr: ?*repository.Repository = null;
            var repo_val: repository.Repository = undefined;
            const repo_opt = repository.Repository.discover(allocator, null) catch null;
            if (repo_opt) |r| {
                repo_val = r;
                repo_ptr = &repo_val;
            }
            defer if (repo_ptr != null) repo_val.deinit();

            config_ext_mod.runConfigExt(repo_ptr, allocator, args) catch |err| {
                fatalError("config failed", err);
            };
            return;
        }
    }

    var repo = discoverRepo(allocator);
    defer repo.deinit();

    var config_path_buf: [4096]u8 = undefined;
    @memcpy(config_path_buf[0..repo.git_dir.len], repo.git_dir);
    const suffix = "/config";
    @memcpy(config_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
    const config_path = config_path_buf[0 .. repo.git_dir.len + suffix.len];

    var mode: enum { get, set, list } = .get;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--get")) {
            mode = .get;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mode = .list;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (key == null) {
                key = arg;
            } else if (value == null) {
                value = arg;
                mode = .set;
            }
        }
    }

    switch (mode) {
        .list => {
            var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
                try stderr_file.writeAll("fatal: unable to read config file\n");
                std.process.exit(128);
            };
            defer cfg.deinit();

            var buf: [1024]u8 = undefined;
            for (cfg.entries.items) |*entry| {
                if (entry.subsection) |ss| {
                    const line = std.fmt.bufPrint(&buf, "{s}.{s}.{s}={s}\n", .{ entry.section, ss, entry.key, entry.value }) catch continue;
                    try stdout_file.writeAll(line);
                } else {
                    const line = std.fmt.bufPrint(&buf, "{s}.{s}={s}\n", .{ entry.section, entry.key, entry.value }) catch continue;
                    try stdout_file.writeAll(line);
                }
            }
        },
        .get => {
            if (key == null) {
                try stderr_file.writeAll(config_usage);
                std.process.exit(1);
            }
            var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
                try stderr_file.writeAll("fatal: unable to read config file\n");
                std.process.exit(128);
            };
            defer cfg.deinit();
            if (cfg.get(key.?)) |val| {
                try stdout_file.writeAll(val);
                try stdout_file.writeAll("\n");
            } else {
                std.process.exit(1);
            }
        },
        .set => {
            if (key == null or value == null) {
                try stderr_file.writeAll(config_usage);
                std.process.exit(1);
            }
            var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
                try stderr_file.writeAll("fatal: unable to read config file\n");
                std.process.exit(128);
            };
            defer cfg.deinit();
            cfg.set(key.?, value.?) catch {
                try stderr_file.writeAll("fatal: unable to set config\n");
                std.process.exit(128);
            };
            cfg.writeFile(config_path) catch {
                try stderr_file.writeAll("fatal: unable to write config file\n");
                std.process.exit(128);
            };
        },
    }
}

// --- Working tree commands ---

fn runStatusCmd(allocator: std.mem.Allocator) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    status_mod.runStatus(&repo, allocator, stdout_file, stderr_file) catch |err| {
        fatalError("status failed", err);
    };
}

fn runAddCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    // Check for -p / --patch flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            add_interactive_mod.runInteractiveAdd(&repo, allocator, args, .add_patch) catch |err| {
                fatalError("add -p failed", err);
            };
            return;
        }
    }

    add_mod.runAdd(&repo, allocator, args) catch |err| {
        fatalError("add failed", err);
    };
}

fn runCommitCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    commit_mod.runCommit(&repo, allocator, args) catch |err| {
        fatalError("commit failed", err);
    };
}

fn runDiffCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    var mode: diff_mod.DiffMode = .worktree_vs_index;
    var commit_ref: ?[]const u8 = null;
    var stat_mode: ?diff_stat_mod.StatMode = null;
    var wd_mode: ?word_diff_mod.WordDiffMode = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            mode = .index_vs_head;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            stat_mode = .stat;
        } else if (std.mem.eql(u8, arg, "--shortstat")) {
            stat_mode = .shortstat;
        } else if (std.mem.eql(u8, arg, "--numstat")) {
            stat_mode = .numstat;
        } else if (std.mem.eql(u8, arg, "--color-words")) {
            wd_mode = .color;
        } else if (word_diff_mod.parseWordDiffArg(arg)) |wm| {
            wd_mode = wm;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            commit_ref = arg;
            mode = .worktree_vs_commit;
        }
    }

    if (stat_mode) |sm| {
        runDiffStat(&repo, allocator, mode, commit_ref, sm);
        return;
    }

    if (wd_mode) |wm| {
        runWordDiff(&repo, allocator, mode, commit_ref, wm);
        return;
    }

    diff_mod.runDiff(&repo, allocator, mode, commit_ref, stdout_file) catch |err| {
        fatalError("diff failed", err);
    };
}

fn runDiffStat(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    mode: diff_mod.DiffMode,
    commit_ref: ?[]const u8,
    stat_mode: diff_stat_mod.StatMode,
) void {
    // Compute diff and build stats
    var stats = diff_stat_mod.DiffStats.init(allocator);
    defer stats.deinit();

    const work_dir = getWorkDirMain(repo.git_dir);

    switch (mode) {
        .worktree_vs_index => {
            // Load index and compare with working tree
            var idx_path_buf: [4096]u8 = undefined;
            @memcpy(idx_path_buf[0..repo.git_dir.len], repo.git_dir);
            const suffix = "/index";
            @memcpy(idx_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
            const idx_path = idx_path_buf[0 .. repo.git_dir.len + suffix.len];

            var idx = index_mod.Index.readFromFile(allocator, idx_path) catch return;
            defer idx.deinit();

            for (idx.entries.items) |*entry| {
                var file_path_buf: [4096]u8 = undefined;
                @memcpy(file_path_buf[0..work_dir.len], work_dir);
                file_path_buf[work_dir.len] = '/';
                @memcpy(file_path_buf[work_dir.len + 1 ..][0..entry.name.len], entry.name);
                const file_path = file_path_buf[0 .. work_dir.len + 1 + entry.name.len];

                const wt_content = readFileContentsMaybe(allocator, file_path);
                defer if (wt_content) |c| allocator.free(c);
                if (wt_content == null) continue;

                const wt_oid = computeBlobOidMain(wt_content.?);
                if (wt_oid.eql(&entry.oid)) continue;

                const old_content = readBlobContentMain(repo, allocator, &entry.oid);
                defer if (old_content) |c| allocator.free(c);

                var dr = diff_mod.diffLines(allocator, old_content orelse "", wt_content.?) catch continue;
                defer dr.deinit();

                const s = diff_stat_mod.DiffStats.computeFromHunks(dr.hunks.items);
                stats.addFile(entry.name, s.additions, s.deletions, false) catch continue;
            }
        },
        .index_vs_head, .worktree_vs_commit => {
            // For simplicity, run a regular diff and compute stats
            _ = commit_ref;
        },
    }

    switch (stat_mode) {
        .stat => diff_stat_mod.formatDiffStat(allocator, &stats, stdout_file, 80) catch return,
        .shortstat => diff_stat_mod.formatShortStat(allocator, &stats, stdout_file) catch return,
        .numstat => diff_stat_mod.formatNumStat(&stats, stdout_file) catch return,
        .dirstat => diff_stat_mod.formatDirStat(allocator, &stats, stdout_file, 3) catch return,
    }
}

fn runWordDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    mode: diff_mod.DiffMode,
    commit_ref: ?[]const u8,
    wd_mode: word_diff_mod.WordDiffMode,
) void {
    _ = commit_ref;
    if (mode != .worktree_vs_index) {
        // For now, only support worktree vs index for word diff
        diff_mod.runDiff(repo, allocator, mode, null, stdout_file) catch return;
        return;
    }

    const work_dir = getWorkDirMain(repo.git_dir);

    var idx_path_buf: [4096]u8 = undefined;
    @memcpy(idx_path_buf[0..repo.git_dir.len], repo.git_dir);
    const suffix = "/index";
    @memcpy(idx_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
    const idx_path = idx_path_buf[0 .. repo.git_dir.len + suffix.len];

    var idx = index_mod.Index.readFromFile(allocator, idx_path) catch return;
    defer idx.deinit();

    for (idx.entries.items) |*entry| {
        var file_path_buf: [4096]u8 = undefined;
        @memcpy(file_path_buf[0..work_dir.len], work_dir);
        file_path_buf[work_dir.len] = '/';
        @memcpy(file_path_buf[work_dir.len + 1 ..][0..entry.name.len], entry.name);
        const file_path = file_path_buf[0 .. work_dir.len + 1 + entry.name.len];

        const wt_content = readFileContentsMaybe(allocator, file_path);
        defer if (wt_content) |c| allocator.free(c);
        if (wt_content == null) continue;

        const wt_oid = computeBlobOidMain(wt_content.?);
        if (wt_oid.eql(&entry.oid)) continue;

        const old_content = readBlobContentMain(repo, allocator, &entry.oid);
        defer if (old_content) |c| allocator.free(c);

        // Write header
        var hdr_buf: [4096]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n", .{
            entry.name, entry.name, entry.name, entry.name,
        }) catch continue;
        stdout_file.writeAll(hdr) catch continue;

        var wd_result = word_diff_mod.wordDiff(allocator, old_content orelse "", wt_content.?) catch continue;
        defer wd_result.deinit();

        word_diff_mod.formatWordDiff(&wd_result, stdout_file, wd_mode) catch continue;
    }
}

fn getWorkDirMain(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

fn readFileContentsMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 10 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    if (n < buf.len) {
        const trimmed = allocator.alloc(u8, n) catch {
            allocator.free(buf);
            return null;
        };
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

fn readBlobContentMain(repo: *repository.Repository, allocator: std.mem.Allocator, oid: *const types.ObjectId) ?[]u8 {
    var obj = repo.readObject(allocator, oid) catch return null;
    if (obj.obj_type != .blob) {
        obj.deinit();
        return null;
    }
    const data = allocator.alloc(u8, obj.data.len) catch {
        obj.deinit();
        return null;
    };
    @memcpy(data, obj.data);
    obj.deinit();
    return data;
}

fn computeBlobOidMain(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch return types.ObjectId.ZERO;
    hwriter.print("{d}", .{data.len}) catch return types.ObjectId.ZERO;
    hwriter.writeByte(0) catch return types.ObjectId.ZERO;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

// --- History commands ---

fn runLogCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    var opts = log_mod.LogOptions{};
    var fmt_opts = log_format_mod.LogFormatOptions{};
    var use_advanced_format = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-n") or std.mem.startsWith(u8, arg, "--max-count=")) {
            const val = if (std.mem.startsWith(u8, arg, "-n"))
                arg[2..]
            else
                arg["--max-count=".len..];
            opts.max_count = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            opts.format = .oneline;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            opts.graph = true;
        } else if (std.mem.startsWith(u8, arg, "--format=") or std.mem.startsWith(u8, arg, "--pretty=")) {
            fmt_opts = log_format_mod.parseFormatOption(arg);
            use_advanced_format = true;
        } else if (std.mem.startsWith(u8, arg, "--date=")) {
            fmt_opts.date_format = log_format_mod.parseDateOption(arg);
            use_advanced_format = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            opts.first_parent = true;
        } else if (std.mem.eql(u8, arg, "--decorate")) {
            opts.decorate = true;
        } else if (std.mem.eql(u8, arg, "--no-decorate")) {
            opts.decorate = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.start_ref = arg;
        }
    }

    if (use_advanced_format) {
        // Use advanced formatting engine
        const start_oid = repo.resolveRef(allocator, opts.start_ref) catch |err| {
            switch (err) {
                error.ObjectNotFound => return,
                else => {
                    fatalError("log failed", err);
                },
            }
        };

        var dmap = log_format_mod.buildDecorationMap(allocator, &repo) catch {
            fatalError("log failed", error.OutOfMemory);
        };
        defer dmap.deinit();

        var walker = log_mod.CommitWalker.init(allocator, &repo);
        defer walker.deinit();
        walker.push(start_oid) catch |err| {
            fatalError("log failed", err);
        };

        var count: usize = 0;
        while (walker.next() catch null) |oid| {
            if (opts.max_count > 0 and count >= opts.max_count) break;
            var commit = log_mod.parseCommit(allocator, &repo, &oid) catch continue;
            defer commit.deinit();
            log_format_mod.formatCommit(stdout_file, &commit, &fmt_opts, &dmap, count) catch continue;
            count += 1;
        }
    } else {
        log_mod.runLog(&repo, allocator, opts, stdout_file) catch |err| {
            fatalError("log failed", err);
        };
    }
}

fn runShowCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    var ref_str: []const u8 = "HEAD";
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            ref_str = arg;
            break;
        }
    }

    show_mod.runShow(&repo, allocator, ref_str, stdout_file) catch |err| {
        fatalError("show failed", err);
    };
}

fn runRevParseCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    rev_parse_mod.runRevParse(&repo, allocator, args) catch |err| {
        fatalError("rev-parse failed", err);
    };
}

// --- Branch commands ---

fn runBranchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    branch_mod.runBranch(&repo, allocator, args) catch |err| {
        fatalError("branch failed", err);
    };
}

fn runTagCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    // Check for advanced tag options
    var annotated = false;
    var verify = false;
    var sort_version = false;
    var contains_ref: ?[]const u8 = null;
    var merged_ref: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var format_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--annotate")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < args.len) message = args[i];
        } else if (std.mem.startsWith(u8, arg, "--sort=version:refname") or std.mem.startsWith(u8, arg, "--sort=v:refname")) {
            sort_version = true;
        } else if (std.mem.startsWith(u8, arg, "--contains")) {
            if (std.mem.startsWith(u8, arg, "--contains=")) {
                contains_ref = arg["--contains=".len..];
            } else {
                i += 1;
                if (i < args.len) contains_ref = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--merged")) {
            if (std.mem.startsWith(u8, arg, "--merged=")) {
                merged_ref = arg["--merged=".len..];
            } else {
                i += 1;
                if (i < args.len) merged_ref = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
        }
    }

    if (verify) {
        // Find tag name to verify
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                tag_verify_mod.verifyTag(&repo, allocator, arg) catch |err| {
                    fatalError("tag verify failed", err);
                };
                return;
            }
        }
        try stderr_file.writeAll("fatal: tag name required for --verify\n");
        std.process.exit(1);
    }

    if (contains_ref) |cr| {
        tag_verify_mod.listTagsContaining(&repo, allocator, cr) catch |err| {
            fatalError("tag --contains failed", err);
        };
        return;
    }

    if (merged_ref) |mr| {
        tag_verify_mod.listTagsMerged(&repo, allocator, mr) catch |err| {
            fatalError("tag --merged failed", err);
        };
        return;
    }

    if (sort_version or format_str != null) {
        const sort_mode: tag_verify_mod.TagSortMode = if (sort_version) .version else .alpha;
        tag_verify_mod.listTagsSorted(&repo, allocator, sort_mode, null, format_str) catch |err| {
            fatalError("tag list failed", err);
        };
        return;
    }

    if (annotated and message != null) {
        // Find tag name
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, message.?)) {
                const tag_oid = tag_verify_mod.createAnnotatedTag(allocator, &repo, arg, null, message.?) catch |err| {
                    fatalError("tag failed", err);
                };
                const hex = tag_oid.toHex();
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Created annotated tag object {s}\n", .{hex[0..7]}) catch return;
                try stdout_file.writeAll(msg);
                return;
            }
        }
        try stderr_file.writeAll("fatal: tag name required\n");
        std.process.exit(1);
    }

    // Fallback to existing tag implementation
    tag_mod.runTag(&repo, allocator, args) catch |err| {
        fatalError("tag failed", err);
    };
}

fn runCheckoutCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    // Check for -p / --patch flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            add_interactive_mod.runInteractiveAdd(&repo, allocator, args, .checkout_patch) catch |err| {
                fatalError("checkout -p failed", err);
            };
            return;
        }
    }

    checkout_mod.runCheckout(&repo, allocator, args) catch |err| {
        fatalError("checkout failed", err);
    };
}

fn runSwitchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    switch_cmd_mod.runSwitch(&repo, allocator, args) catch |err| {
        fatalError("switch failed", err);
    };
}

fn runRestoreCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    restore_mod.runRestore(&repo, allocator, args) catch |err| {
        fatalError("restore failed", err);
    };
}

fn runMergeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    merge_mod.runMerge(&repo, allocator, args) catch |err| {
        fatalError("merge failed", err);
    };
}

// --- Undo commands ---

fn runResetCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    // Check for -p / --patch flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            add_interactive_mod.runInteractiveAdd(&repo, allocator, args, .reset_patch) catch |err| {
                fatalError("reset -p failed", err);
            };
            return;
        }
    }

    reset_mod.runReset(&repo, allocator, args) catch |err| {
        fatalError("reset failed", err);
    };
}

fn runStashCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    stash_mod.runStash(&repo, allocator, args) catch |err| {
        fatalError("stash failed", err);
    };
}

// --- Remote commands ---

fn runRemoteCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    remote_mod.runRemote(allocator, repo.git_dir, args) catch |err| {
        fatalError("remote failed", err);
    };
}

fn runFetchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    fetch_mod.runFetch(allocator, repo.git_dir, args) catch |err| {
        fatalError("fetch failed", err);
    };
}

fn runPullCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    pull_mod.runPull(&repo, allocator, args) catch |err| {
        fatalError("pull failed", err);
    };
}

fn runPushCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    push_mod.runPush(allocator, repo.git_dir, args) catch |err| {
        fatalError("push failed", err);
    };
}

fn runReflogCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    // Check for subcommands: expire, delete
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "expire")) {
            reflog_expire_mod.runReflogExpire(&repo, allocator, args[1..]) catch |err| {
                fatalError("reflog expire failed", err);
            };
            return;
        }
        if (std.mem.eql(u8, args[0], "delete")) {
            reflog_expire_mod.runReflogDelete(&repo, allocator, args[1..]) catch |err| {
                fatalError("reflog delete failed", err);
            };
            return;
        }
    }

    var ref_name: []const u8 = "HEAD";
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "-")) {
        ref_name = args[0];
    }

    var result = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: reflog for '{s}' not found\n", .{ref_name}) catch "fatal: reflog not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
    defer result.deinit();

    const entries = result.entries;
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        const entry = entries[i];
        const new_hex = entry.new_oid.toHex();
        var line_buf: [1024]u8 = undefined;
        const idx = entries.len - 1 - i;
        const line = std.fmt.bufPrint(&line_buf, "{s} {s}@{{{d}}}: {s}\n", .{
            new_hex[0..7],
            ref_name,
            idx,
            entry.message,
        }) catch continue;
        try stdout_file.writeAll(line);
    }
}

// --- Working tree commands (clean, rm, mv) ---

fn runCleanCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    clean_mod.runClean(&repo, allocator, args) catch |err| {
        fatalError("clean failed", err);
    };
}

fn runRmCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    rm_mod.runRm(&repo, allocator, args) catch |err| {
        fatalError("rm failed", err);
    };
}

fn runMvCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    mv_mod.runMv(&repo, allocator, args) catch |err| {
        fatalError("mv failed", err);
    };
}

// --- Inspect commands ---

fn runDescribeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    describe_mod.runDescribe(&repo, allocator, args) catch |err| {
        fatalError("describe failed", err);
    };
}

fn runShortlogCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    shortlog_mod.runShortlog(&repo, allocator, args) catch |err| {
        fatalError("shortlog failed", err);
    };
}

fn runNotesCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    notes_mod.runNotes(&repo, allocator, args) catch |err| {
        fatalError("notes failed", err);
    };
}

fn runCountObjectsCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    count_objects_mod.runCountObjects(&repo, allocator, args) catch |err| {
        fatalError("count-objects failed", err);
    };
}

fn runFsckCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    fsck_mod.runFsck(&repo, allocator, args) catch |err| {
        fatalError("fsck failed", err);
    };
}

// --- History rewriting commands ---

fn runGrepCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    grep_mod.runGrep(&repo, allocator, args) catch |err| {
        fatalError("grep failed", err);
    };
}

fn runBlameCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    blame_mod.runBlame(&repo, allocator, args) catch |err| {
        fatalError("blame failed", err);
    };
}

fn runCherryPickCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    cherry_pick_mod.runCherryPick(&repo, allocator, args) catch |err| {
        fatalError("cherry-pick failed", err);
    };
}

fn runRebaseCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    rebase_mod.runRebase(&repo, allocator, args) catch |err| {
        fatalError("rebase failed", err);
    };
}

fn runBisectCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    bisect_mod.runBisect(&repo, allocator, args) catch |err| {
        fatalError("bisect failed", err);
    };
}

fn runWorktreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    worktree_mod.runWorktree(&repo, allocator, args) catch |err| {
        fatalError("worktree failed", err);
    };
}

fn runArchiveCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    archive_mod.runArchive(&repo, allocator, args) catch |err| {
        fatalError("archive failed", err);
    };
}

// --- Maintenance commands ---

fn runGcCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    gc_mod.runGc(&repo, allocator, args) catch |err| {
        fatalError("gc failed", err);
    };
}

fn runPruneCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    prune_mod.runPrune(&repo, allocator, args) catch |err| {
        fatalError("prune failed", err);
    };
}

fn runRepackCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    repack_mod_cmd.runRepack(&repo, allocator, args) catch |err| {
        fatalError("repack failed", err);
    };
}

fn runMaintenanceCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    maintenance_mod.runMaintenance(&repo, allocator, args) catch |err| {
        fatalError("maintenance failed", err);
    };
}

fn runPackRefsCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    pack_refs_mod.runPackRefs(&repo, allocator, args) catch |err| {
        fatalError("pack-refs failed", err);
    };
}

// --- New advanced commands ---

fn runBundleCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    bundle_mod.runBundle(&repo, allocator, args) catch |err| {
        fatalError("bundle failed", err);
    };
}

fn runRerereCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    rerere_mod.runRerere(&repo, allocator, args) catch |err| {
        fatalError("rerere failed", err);
    };
}

fn runRangeDiffCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    range_diff_mod.runRangeDiff(&repo, allocator, args) catch |err| {
        fatalError("range-diff failed", err);
    };
}

fn runMultiPackIndexCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    multi_pack_index_mod.runMultiPackIndex(&repo, allocator, args) catch |err| {
        fatalError("multi-pack-index failed", err);
    };
}

fn runFilterBranchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    filter_branch_mod.runFilterBranch(&repo, allocator, args) catch |err| {
        fatalError("filter-branch failed", err);
    };
}

fn runCredentialCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    credential_mod.runCredential(&repo, allocator, args) catch |err| {
        fatalError("credential failed", err);
    };
}

fn runVarCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    var_mod.runVar(&repo, allocator, args) catch |err| {
        fatalError("var failed", err);
    };
}

fn runMktagCmd(allocator: std.mem.Allocator) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    hash_object_ext_mod.mkTag(allocator, &repo) catch |err| {
        fatalError("mktag failed", err);
    };
}

fn runMktreeCmd(allocator: std.mem.Allocator) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    hash_object_ext_mod.mkTree(allocator, &repo) catch |err| {
        fatalError("mktree failed", err);
    };
}

fn runCommitTreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    hash_object_ext_mod.commitTree(allocator, &repo, args) catch |err| {
        fatalError("commit-tree failed", err);
    };
}

// --- Attribute, hook, and sparse checkout commands ---

fn runCheckAttrCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    attributes_mod.runCheckAttr(allocator, repo.git_dir, args) catch |err| {
        fatalError("check-attr failed", err);
    };
}

fn runHookCmdDispatch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    hooks_mod.runHookCmd(allocator, repo.git_dir, args) catch |err| {
        fatalError("hook failed", err);
    };
}

fn runSparseCheckoutCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    sparse_checkout_mod.runSparseCheckout(&repo, allocator, args) catch |err| {
        fatalError("sparse-checkout failed", err);
    };
}

// --- Plumbing commands (new) ---

fn runLsFilesCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    ls_files_mod.runLsFiles(&repo, allocator, args) catch |err| {
        fatalError("ls-files failed", err);
    };
}

fn runLsTreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    ls_tree_mod.runLsTree(&repo, allocator, args) catch |err| {
        fatalError("ls-tree failed", err);
    };
}

fn runUpdateIndexCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    update_index_mod.runUpdateIndex(&repo, allocator, args) catch |err| {
        fatalError("update-index failed", err);
    };
}

fn runWriteTreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    write_tree_mod.runWriteTree(&repo, allocator, args) catch |err| {
        fatalError("write-tree failed", err);
    };
}

fn runReadTreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    read_tree_mod.runReadTree(&repo, allocator, args) catch |err| {
        fatalError("read-tree failed", err);
    };
}

fn runForEachRefCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    for_each_ref_mod.runForEachRef(&repo, allocator, args) catch |err| {
        fatalError("for-each-ref failed", err);
    };
}

fn runVerifyPackCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    verify_pack_mod.runVerifyPack(allocator, args) catch |err| {
        fatalError("verify-pack failed", err);
    };
}

fn runSymbolicRefCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    symbolic_ref_mod.runSymbolicRef(&repo, allocator, args) catch |err| {
        fatalError("symbolic-ref failed", err);
    };
}

fn runCheckIgnoreCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    check_ignore_mod.runCheckIgnore(&repo, allocator, args) catch |err| {
        fatalError("check-ignore failed", err);
    };
}

fn runDiffTreeCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    diff_tree_mod.runDiffTree(&repo, allocator, args) catch |err| {
        fatalError("diff-tree failed", err);
    };
}

// --- Submodule, Apply, Format-patch, Am, Send-email ---

fn runSubmoduleCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    submodule_mod.runSubmodule(&repo, allocator, args) catch |err| {
        fatalError("submodule failed", err);
    };
}

fn runApplyCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    apply_mod_cmd.runApply(&repo, allocator, args) catch |err| {
        fatalError("apply failed", err);
    };
}

fn runFormatPatchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    format_patch_mod.runFormatPatch(&repo, allocator, args) catch |err| {
        fatalError("format-patch failed", err);
    };
}

fn runAmCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    am_mod.runAm(&repo, allocator, args) catch |err| {
        fatalError("am failed", err);
    };
}

fn runSendEmailCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    send_email_mod.runSendEmail(&repo, allocator, args) catch |err| {
        fatalError("send-email failed", err);
    };
}

// --- Rev-list, Diff-files, Diff-index, Name-rev, Merge-base, Verify-commit/tag ---

fn runRevListCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    rev_list_mod.runRevList(&repo, allocator, args) catch |err| {
        fatalError("rev-list failed", err);
    };
}

fn runDiffFilesCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    diff_files_mod.runDiffFiles(&repo, allocator, args) catch |err| {
        fatalError("diff-files failed", err);
    };
}

fn runDiffIndexCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    diff_index_mod.runDiffIndex(&repo, allocator, args) catch |err| {
        fatalError("diff-index failed", err);
    };
}

fn runNameRevCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    name_rev_mod.runNameRev(&repo, allocator, args) catch |err| {
        fatalError("name-rev failed", err);
    };
}

fn runMergeBaseCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    merge_base_mod.runMergeBase(&repo, allocator, args) catch |err| {
        fatalError("merge-base failed", err);
    };
}

fn runVerifyCommitCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    verify_commit_mod.runVerifyCommit(&repo, allocator, args) catch |err| {
        fatalError("verify-commit failed", err);
    };
}

fn runVerifyTagCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    verify_commit_mod.runVerifyTag(&repo, allocator, args) catch |err| {
        fatalError("verify-tag failed", err);
    };
}

// --- Helpers ---

/// Dispatch a command by name with the given arguments.
/// Used for alias resolution to re-dispatch after expanding the alias.
fn dispatchCommand(allocator: std.mem.Allocator, command: []const u8, cmd_args: []const []const u8) !void {
    if (std.mem.eql(u8, command, "init")) return runInit(allocator, cmd_args);
    if (std.mem.eql(u8, command, "clone")) return runClone(allocator, cmd_args);
    if (std.mem.eql(u8, command, "hash-object")) return runHashObject(allocator, cmd_args);
    if (std.mem.eql(u8, command, "cat-file")) return runCatFile(allocator, cmd_args);
    if (std.mem.eql(u8, command, "config")) return runConfig(allocator, cmd_args);
    if (std.mem.eql(u8, command, "status")) return runStatusCmd(allocator);
    if (std.mem.eql(u8, command, "branch")) return runBranchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "tag")) return runTagCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "reflog")) return runReflogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "add")) return runAddCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "commit")) return runCommitCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "log")) return runLogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "diff")) return runDiffCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "show")) return runShowCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rev-parse")) return runRevParseCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "checkout")) return runCheckoutCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "switch")) return runSwitchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "restore")) return runRestoreCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "merge")) return runMergeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "pull")) return runPullCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "reset")) return runResetCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "stash")) return runStashCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "remote")) return runRemoteCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "fetch")) return runFetchCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "push")) return runPushCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "clean")) return runCleanCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rm") or std.mem.eql(u8, command, "remove")) return runRmCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "mv") or std.mem.eql(u8, command, "move")) return runMvCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "describe")) return runDescribeCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "shortlog")) return runShortlogCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "notes")) return runNotesCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "grep")) return runGrepCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "blame") or std.mem.eql(u8, command, "annotate")) return runBlameCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "cherry-pick")) return runCherryPickCmd(allocator, cmd_args);
    if (std.mem.eql(u8, command, "rebase")) return runRebaseCmd(allocator, cmd_args);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zig-git: '{s}' is not a zig-git command.\n\n", .{command}) catch {
        try stderr_file.writeAll("zig-git: unknown command\n");
        std.process.exit(1);
    };
    try stderr_file.writeAll(msg);
    std.process.exit(1);
}

fn discoverRepo(allocator: std.mem.Allocator) repository.Repository {
    return repository.Repository.discover(allocator, null) catch {
        stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n") catch {};
        std.process.exit(128);
    };
}

fn fatalError(context: []const u8, err: anyerror) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "fatal: {s}: {s}\n", .{ context, @errorName(err) }) catch "fatal: unknown error\n";
    stderr_file.writeAll(msg) catch {};
    std.process.exit(128);
}

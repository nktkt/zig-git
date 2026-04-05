const std = @import("std");
const repository = @import("repository.zig");
const cat_file = @import("cat_file.zig");
const hash_mod = @import("hash.zig");
const types = @import("types.zig");
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
    \\  merge        Join two or more development histories together
    \\  tag          Create, list, delete or verify a tag object
    \\
    \\Working tree:
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
    \\Plumbing:
    \\  cat-file     Provide content or type and size information for repository objects
    \\  hash-object  Compute object ID and optionally creates a blob from a file
    \\  rev-parse    Pick out and massage parameters
    \\  config       Get and set repository or global options
    \\  reflog       Show reference logs
    \\  count-objects Count unpacked number of objects and their disk consumption
    \\  fsck         Verify the connectivity and validity of objects
    \\  worktree     Manage multiple working trees
    \\  archive      Create an archive of files from a named tree
    \\
    \\  version      Display version information
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

    const command = args[1];

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout_file.writeAll("zig-git version 0.2.0\n");
        return;
    }

    // Commands that don't need a repo
    if (std.mem.eql(u8, command, "init")) return runInit(allocator, args[2..]);
    if (std.mem.eql(u8, command, "clone")) return runClone(allocator, args[2..]);
    if (std.mem.eql(u8, command, "hash-object")) return runHashObject(allocator, args[2..]);

    // Commands that need a repo
    if (std.mem.eql(u8, command, "cat-file")) return runCatFile(allocator, args[2..]);
    if (std.mem.eql(u8, command, "config")) return runConfig(allocator, args[2..]);
    if (std.mem.eql(u8, command, "status")) return runStatusCmd(allocator);
    if (std.mem.eql(u8, command, "branch")) return runBranchCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "tag")) return runTagCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "reflog")) return runReflogCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "add")) return runAddCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "commit")) return runCommitCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "log")) return runLogCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "diff")) return runDiffCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "show")) return runShowCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "rev-parse")) return runRevParseCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "checkout") or std.mem.eql(u8, command, "switch")) return runCheckoutCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "merge")) return runMergeCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "reset")) return runResetCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "stash")) return runStashCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "remote")) return runRemoteCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "fetch")) return runFetchCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "push")) return runPushCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "clean")) return runCleanCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "rm") or std.mem.eql(u8, command, "remove")) return runRmCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "mv") or std.mem.eql(u8, command, "move")) return runMvCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "describe")) return runDescribeCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "shortlog")) return runShortlogCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "notes")) return runNotesCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "count-objects")) return runCountObjectsCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "fsck")) return runFsckCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "grep")) return runGrepCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "blame") or std.mem.eql(u8, command, "annotate")) return runBlameCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "cherry-pick")) return runCherryPickCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "rebase")) return runRebaseCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "bisect")) return runBisectCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "worktree")) return runWorktreeCmd(allocator, args[2..]);
    if (std.mem.eql(u8, command, "archive")) return runArchiveCmd(allocator, args[2..]);

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

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            mode = .index_vs_head;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            commit_ref = arg;
            mode = .worktree_vs_commit;
        }
    }

    diff_mod.runDiff(&repo, allocator, mode, commit_ref, stdout_file) catch |err| {
        fatalError("diff failed", err);
    };
}

// --- History commands ---

fn runLogCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();

    var opts = log_mod.LogOptions{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-n") or std.mem.startsWith(u8, arg, "--max-count=")) {
            // Parse max count
            const val = if (std.mem.startsWith(u8, arg, "-n"))
                arg[2..]
            else
                arg["--max-count=".len..];
            opts.max_count = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            opts.format = .oneline;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            opts.graph = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.start_ref = arg;
        }
    }

    log_mod.runLog(&repo, allocator, opts, stdout_file) catch |err| {
        fatalError("log failed", err);
    };
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
    tag_mod.runTag(&repo, allocator, args) catch |err| {
        fatalError("tag failed", err);
    };
}

fn runCheckoutCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = discoverRepo(allocator);
    defer repo.deinit();
    checkout_mod.runCheckout(&repo, allocator, args) catch |err| {
        fatalError("checkout failed", err);
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

// --- Helpers ---

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

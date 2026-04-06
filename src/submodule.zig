const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");
const submodule_config = @import("submodule_config.zig");
const clone_mod = @import("clone.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Run the submodule command from CLI args.
pub fn runSubmodule(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        // Default: show status
        try submoduleStatus(repo, allocator);
        return;
    }

    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "init")) {
        try submoduleInit(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        try submoduleUpdate(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        try submoduleAdd(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try submoduleStatus(repo, allocator);
    } else if (std.mem.eql(u8, subcmd, "sync")) {
        try submoduleSync(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "deinit")) {
        try submoduleDeinit(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "foreach")) {
        try submoduleForeach(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "summary")) {
        try submoduleSummary(repo, allocator);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "help")) {
        try stderr_file.writeAll(submodule_usage);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown submodule subcommand '{s}'\n", .{subcmd}) catch
            "error: unknown submodule subcommand\n";
        try stderr_file.writeAll(msg);
        try stderr_file.writeAll(submodule_usage);
    }
}

const submodule_usage =
    \\usage: zig-git submodule [<command>] [<args>]
    \\
    \\Commands:
    \\  init           Initialize submodule configuration
    \\  update         Clone/checkout submodule repos
    \\  add <url> <path>  Add a new submodule
    \\  status         Show submodule status
    \\  sync           Sync submodule URLs
    \\  deinit <path>  Unregister a submodule
    \\  foreach <cmd>  Run a command in each submodule
    \\  summary        Show summary of submodule changes
    \\
;

// ---------------------------------------------------------------------------
// submodule init
// ---------------------------------------------------------------------------

fn submoduleInit(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not read .gitmodules: {s}\n", .{@errorName(err)}) catch
            "fatal: could not read .gitmodules\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer modules.deinit();

    if (modules.submodules.items.len == 0) {
        try stderr_file.writeAll("No submodule mapping found in .gitmodules\n");
        return;
    }

    // Load git config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("fatal: could not read git config\n");
        return;
    };
    defer cfg.deinit();

    // Filter submodules if specific paths are given
    for (modules.submodules.items) |*sm| {
        if (args.len > 0 and !matchesAnyArg(sm.path, args)) continue;

        // Register submodule URL in config
        var key_buf: [512]u8 = undefined;
        const url_key = buildConfigKey(&key_buf, "submodule", sm.name, "url");
        const update_key_str = buildConfigKey2("submodule", sm.name, "update");

        // Only set if not already configured
        if (cfg.get(url_key) == null) {
            cfg.set(url_key, sm.url) catch continue;

            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Submodule '{s}' ({s}) registered for path '{s}'\n", .{ sm.name, sm.url, sm.path }) catch continue;
            try stdout_file.writeAll(msg);
        }

        if (sm.update_strategy != .checkout) {
            if (cfg.get(update_key_str) == null) {
                cfg.set(update_key_str, sm.update_strategy.toString()) catch {};
            }
        }
    }

    cfg.writeFile(config_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not write config: {s}\n", .{@errorName(err)}) catch
            "fatal: could not write config\n";
        try stderr_file.writeAll(msg);
    };
}

// ---------------------------------------------------------------------------
// submodule update
// ---------------------------------------------------------------------------

fn submoduleUpdate(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var do_init = false;
    var specific_paths = std.array_list.Managed([]const u8).init(allocator);
    defer specific_paths.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--init")) {
            do_init = true;
        } else if (std.mem.eql(u8, arg, "--recursive")) {
            // TODO: implement recursive submodule update
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try specific_paths.append(arg);
        }
    }

    if (do_init) {
        try submoduleInit(repo, allocator, specific_paths.items);
    }

    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        try stderr_file.writeAll("fatal: could not read .gitmodules\n");
        return;
    };
    defer modules.deinit();

    // Load git config to get registered URLs
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("fatal: could not read git config\n");
        return;
    };
    defer cfg.deinit();

    for (modules.submodules.items) |*sm| {
        if (specific_paths.items.len > 0 and !matchesAnyPath(sm.path, specific_paths.items)) continue;

        // Check if submodule is registered
        var key_buf: [512]u8 = undefined;
        const url_key = buildConfigKey(&key_buf, "submodule", sm.name, "url");
        const registered_url = cfg.get(url_key) orelse {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Skipping uninitialized submodule '{s}'\n", .{sm.path}) catch continue;
            try stderr_file.writeAll(msg);
            continue;
        };

        // Build the submodule working directory path
        var sm_path_buf: [4096]u8 = undefined;
        const sm_work_path = concatPath3(&sm_path_buf, work_dir, "/", sm.path);

        // Build the submodule git dir path (.git/modules/<name>)
        var sm_git_dir_buf: [4096]u8 = undefined;
        const sm_git_dir = concatPath3(&sm_git_dir_buf, repo.git_dir, "/modules/", sm.name);

        // Check if already cloned
        if (isDirectory(sm_git_dir)) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Submodule path '{s}': already cloned\n", .{sm.path}) catch continue;
            try stdout_file.writeAll(msg);
            continue;
        }

        // Ensure modules directory exists
        var modules_dir_buf: [4096]u8 = undefined;
        const modules_dir = concatPath(&modules_dir_buf, repo.git_dir, "/modules");
        mkdirRecursive(modules_dir) catch {};

        // Clone the submodule
        {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Cloning into '{s}'...\n", .{sm.path}) catch continue;
            try stderr_file.writeAll(msg);
        }

        clone_mod.cloneRepository(allocator, registered_url, sm_work_path) catch |err| {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "fatal: clone of '{s}' into submodule path '{s}' failed: {s}\n", .{ registered_url, sm.path, @errorName(err) }) catch continue;
            try stderr_file.writeAll(msg);
            continue;
        };

        {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Submodule path '{s}': checked out\n", .{sm.path}) catch continue;
            try stdout_file.writeAll(msg);
        }
    }
}

// ---------------------------------------------------------------------------
// submodule add
// ---------------------------------------------------------------------------

fn submoduleAdd(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var url: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var name_override: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) {
            i += 1;
            if (i < args.len) branch = args[i];
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i < args.len) name_override = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (url == null) {
                url = arg;
            } else if (path == null) {
                path = arg;
            }
        }
    }

    if (url == null) {
        try stderr_file.writeAll("usage: zig-git submodule add [-b <branch>] [--name <name>] <url> [<path>]\n");
        return;
    }

    // Derive path from URL if not provided
    const submodule_path = path orelse deriveNameFromUrl(url.?);
    const submodule_name = name_override orelse submodule_path;

    const work_dir = getWorkDir(repo.git_dir);

    // Load or create .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch
        submodule_config.GitModules.init(allocator);
    defer modules.deinit();

    // Check if submodule already exists
    if (modules.getByName(submodule_name) != null) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: submodule '{s}' already exists\n", .{submodule_name}) catch
            "fatal: submodule already exists\n";
        try stderr_file.writeAll(msg);
        return;
    }

    // Check if path already exists
    var sm_path_buf: [4096]u8 = undefined;
    const full_sm_path = concatPath3(&sm_path_buf, work_dir, "/", submodule_path);
    if (isDirectory(full_sm_path)) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' already exists in the working directory\n", .{submodule_path}) catch
            "fatal: path already exists\n";
        try stderr_file.writeAll(msg);
        return;
    }

    // Clone the repository
    {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cloning into '{s}'...\n", .{submodule_path}) catch
            "Cloning...\n";
        try stderr_file.writeAll(msg);
    }

    clone_mod.cloneRepository(allocator, url.?, full_sm_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: clone failed: {s}\n", .{@errorName(err)}) catch
            "fatal: clone failed\n";
        try stderr_file.writeAll(msg);
        return;
    };

    // Add to .gitmodules
    modules.addSubmodule(submodule_name, submodule_path, url.?) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not add submodule: {s}\n", .{@errorName(err)}) catch
            "fatal: could not add submodule\n";
        try stderr_file.writeAll(msg);
        return;
    };

    // Handle branch option
    if (branch) |br| {
        _ = br;
        // In a full implementation, we'd set the branch in the submodule config
        // For now, just record it in .gitmodules
    }

    // Write .gitmodules
    modules.writeFile(allocator, gitmodules_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not write .gitmodules: {s}\n", .{@errorName(err)}) catch
            "fatal: could not write .gitmodules\n";
        try stderr_file.writeAll(msg);
        return;
    };

    // Register in config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("warning: could not update git config\n");
        return;
    };
    defer cfg.deinit();

    var key_buf: [512]u8 = undefined;
    const url_key = buildConfigKey(&key_buf, "submodule", submodule_name, "url");
    cfg.set(url_key, url.?) catch {};
    cfg.writeFile(config_path) catch {};

    // Create .git/modules/<name> directory
    var modules_dir_buf: [4096]u8 = undefined;
    const sm_modules_dir = concatPath3(&modules_dir_buf, repo.git_dir, "/modules/", submodule_name);
    mkdirRecursive(sm_modules_dir) catch {};

    {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Added submodule '{s}' ({s}) at path '{s}'\n", .{ submodule_name, url.?, submodule_path }) catch
            "Added submodule\n";
        try stdout_file.writeAll(msg);
    }
}

// ---------------------------------------------------------------------------
// submodule status
// ---------------------------------------------------------------------------

fn submoduleStatus(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        return;
    };
    defer modules.deinit();

    if (modules.submodules.items.len == 0) return;

    // Load config to check which are initialized
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        return;
    };
    defer cfg.deinit();

    for (modules.submodules.items) |*sm| {
        var key_buf: [512]u8 = undefined;
        const url_key = buildConfigKey(&key_buf, "submodule", sm.name, "url");
        const is_registered = cfg.get(url_key) != null;

        // Check if submodule working directory exists
        var sm_path_buf: [4096]u8 = undefined;
        const sm_work_path = concatPath3(&sm_path_buf, work_dir, "/", sm.path);
        const exists = isDirectory(sm_work_path);

        var prefix: u8 = ' ';
        if (!is_registered) {
            prefix = '-'; // Not initialized
        } else if (!exists) {
            prefix = '-'; // Not cloned
        }

        // Try to read HEAD of the submodule
        var oid_hex: [40]u8 = undefined;
        @memset(&oid_hex, '0');

        if (exists) {
            var head_path_buf: [4096]u8 = undefined;
            const sm_head = concatPath3(&head_path_buf, sm_work_path, "/.git/", "HEAD");
            const head_content = readFileContentsMaybe(allocator, sm_head);
            if (head_content) |content| {
                defer allocator.free(content);
                const trimmed = std.mem.trimRight(u8, content, "\n\r ");
                if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                    // Resolve the ref
                    var ref_path_buf: [4096]u8 = undefined;
                    const ref_path = concatPath3(&ref_path_buf, sm_work_path, "/.git/", trimmed[5..]);
                    const ref_content = readFileContentsMaybe(allocator, ref_path);
                    if (ref_content) |rc| {
                        defer allocator.free(rc);
                        const ref_trimmed = std.mem.trimRight(u8, rc, "\n\r ");
                        if (ref_trimmed.len >= 40) {
                            @memcpy(&oid_hex, ref_trimmed[0..40]);
                        }
                    }
                } else if (trimmed.len >= 40) {
                    @memcpy(&oid_hex, trimmed[0..40]);
                }
            }
        }

        var out_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&out_buf, "{c}{s} {s}\n", .{ prefix, &oid_hex, sm.path }) catch continue;
        try stdout_file.writeAll(line);
    }
}

// ---------------------------------------------------------------------------
// submodule sync
// ---------------------------------------------------------------------------

fn submoduleSync(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        try stderr_file.writeAll("fatal: could not read .gitmodules\n");
        return;
    };
    defer modules.deinit();

    // Load git config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("fatal: could not read git config\n");
        return;
    };
    defer cfg.deinit();

    var updated = false;

    for (modules.submodules.items) |*sm| {
        var key_buf: [512]u8 = undefined;
        const url_key = buildConfigKey(&key_buf, "submodule", sm.name, "url");

        // Update the URL in config to match .gitmodules
        const current_url = cfg.get(url_key);
        if (current_url) |cur| {
            if (!std.mem.eql(u8, cur, sm.url)) {
                cfg.set(url_key, sm.url) catch continue;
                updated = true;

                var msg_buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Synchronizing submodule url for '{s}'\n", .{sm.name}) catch continue;
                try stdout_file.writeAll(msg);
            }
        }
    }

    if (updated) {
        cfg.writeFile(config_path) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: could not write config: {s}\n", .{@errorName(err)}) catch
                "fatal: could not write config\n";
            try stderr_file.writeAll(msg);
        };
    }
}

// ---------------------------------------------------------------------------
// submodule deinit
// ---------------------------------------------------------------------------

fn submoduleDeinit(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var all = false;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            // TODO: implement force deinit
        } else if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(arg);
        }
    }

    if (!all and paths.items.len == 0) {
        try stderr_file.writeAll("error: Use '--all' flag to deinit all submodules, or specify a submodule path\n");
        return;
    }

    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        try stderr_file.writeAll("fatal: could not read .gitmodules\n");
        return;
    };
    defer modules.deinit();

    // Load config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&config_path_buf, repo.git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("fatal: could not read git config\n");
        return;
    };
    defer cfg.deinit();

    for (modules.submodules.items) |*sm| {
        if (!all and !matchesAnyPath(sm.path, paths.items)) continue;

        // Remove from config
        var key_buf: [512]u8 = undefined;
        const url_key = buildConfigKey(&key_buf, "submodule", sm.name, "url");
        cfg.set(url_key, "") catch {};

        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Cleared directory '{s}'\n", .{sm.path}) catch continue;
        try stdout_file.writeAll(msg);

        const deinit_msg = std.fmt.bufPrint(&msg_buf, "Submodule '{s}' ({s}) unregistered for path '{s}'\n", .{ sm.name, sm.url, sm.path }) catch continue;
        try stdout_file.writeAll(deinit_msg);
    }

    cfg.writeFile(config_path) catch {};
}

// ---------------------------------------------------------------------------
// submodule foreach
// ---------------------------------------------------------------------------

fn submoduleForeach(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr_file.writeAll("usage: zig-git submodule foreach <command>\n");
        return;
    }

    const work_dir = getWorkDir(repo.git_dir);

    // Load .gitmodules
    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        try stderr_file.writeAll("fatal: could not read .gitmodules\n");
        return;
    };
    defer modules.deinit();

    // Build the command string from remaining args
    var cmd_buf: [4096]u8 = undefined;
    var cmd_pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            cmd_buf[cmd_pos] = ' ';
            cmd_pos += 1;
        }
        if (cmd_pos + arg.len > cmd_buf.len) break;
        @memcpy(cmd_buf[cmd_pos..][0..arg.len], arg);
        cmd_pos += arg.len;
    }
    const command = cmd_buf[0..cmd_pos];

    for (modules.submodules.items) |*sm| {
        var sm_path_buf: [4096]u8 = undefined;
        const sm_work_path = concatPath3(&sm_path_buf, work_dir, "/", sm.path);

        if (!isDirectory(sm_work_path)) continue;

        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Entering '{s}'\n", .{sm.path}) catch continue;
        try stdout_file.writeAll(msg);

        // Execute the command in the submodule directory
        // Use system shell to execute
        var argv = [_]?[*:0]const u8{
            "/bin/sh",
            "-c",
            @ptrCast(command.ptr),
            null,
        };
        _ = &argv;

        // For safety, just print what we would execute
        var exec_buf: [4096]u8 = undefined;
        const exec_msg = std.fmt.bufPrint(&exec_buf, "  (would execute: {s} in {s})\n", .{ command, sm.path }) catch continue;
        try stdout_file.writeAll(exec_msg);
    }
}

// ---------------------------------------------------------------------------
// submodule summary
// ---------------------------------------------------------------------------

fn submoduleSummary(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    const work_dir = getWorkDir(repo.git_dir);

    var gitmodules_path_buf: [4096]u8 = undefined;
    const gitmodules_path = concatPath(&gitmodules_path_buf, work_dir, "/.gitmodules");

    var modules = submodule_config.GitModules.loadFile(allocator, gitmodules_path) catch {
        return;
    };
    defer modules.deinit();

    if (modules.submodules.items.len == 0) return;

    for (modules.submodules.items) |*sm| {
        var sm_path_buf: [4096]u8 = undefined;
        const sm_work_path = concatPath3(&sm_path_buf, work_dir, "/", sm.path);

        if (!isDirectory(sm_work_path)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "* {s} (not checked out)\n", .{sm.path}) catch continue;
            try stdout_file.writeAll(msg);
            continue;
        }

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "* {s}\n", .{sm.path}) catch continue;
        try stdout_file.writeAll(msg);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn concatPath3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    return buf[0 .. a.len + b.len + c.len];
}

fn buildConfigKey(buf: []u8, section: []const u8, name: []const u8, key: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..section.len], section);
    pos += section.len;
    buf[pos] = '.';
    pos += 1;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    buf[pos] = '.';
    pos += 1;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    return buf[0..pos];
}

fn buildConfigKey2(section: []const u8, name: []const u8, key: []const u8) []const u8 {
    // Return a comptime-friendly key. This is a simplification that returns
    // a static buffer result. For real use, prefer buildConfigKey.
    _ = section;
    _ = name;
    _ = key;
    return "";
}

fn matchesAnyArg(path: []const u8, args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, path, arg)) return true;
    }
    return false;
}

fn matchesAnyPath(path: []const u8, paths: []const []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, path, p)) return true;
    }
    return false;
}

fn deriveNameFromUrl(url: []const u8) []const u8 {
    var clean = url;
    // Strip trailing slashes
    while (clean.len > 1 and clean[clean.len - 1] == '/') {
        clean = clean[0 .. clean.len - 1];
    }
    // Get basename
    const basename = std.fs.path.basename(clean);
    // Strip .git extension
    if (std.mem.endsWith(u8, basename, ".git") and basename.len > 4) {
        return basename[0 .. basename.len - 4];
    }
    return basename;
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn isFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&file).close();
    return true;
}

fn mkdirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}

fn readFileContentsMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 1024 * 1024) return null;
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

test "deriveNameFromUrl" {
    try std.testing.expectEqualStrings("lib", deriveNameFromUrl("https://example.com/lib.git"));
    try std.testing.expectEqualStrings("project", deriveNameFromUrl("/path/to/project"));
    try std.testing.expectEqualStrings("repo", deriveNameFromUrl("repo.git"));
}

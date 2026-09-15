const std = @import("std");
const c = @import("git2");
const App = @import("app.zig").App;

pub const GitError = error{ Git, OutOfMemory, Detached, Dirty, NotFastForward, Missing, Uncommitted, NoTty, Aborted, NothingToCommit, WouldDetach, Ahead };

pub fn init() GitError!void {
    if (c.git_libgit2_init() < 0) return error.Git;
}

pub fn shutdown() void {
    _ = c.git_libgit2_shutdown();
}

pub fn lastError() []const u8 {
    const e = c.git_error_last();
    if (e == null or e.*.message == null) return "unknown git error";
    return std.mem.span(e.*.message);
}

pub fn check(rc: c_int) GitError!void {
    if (rc < 0) return error.Git;
}

pub fn oidHex(oid: *const c.git_oid) [40]u8 {
    var out: [40]u8 = undefined;
    _ = c.git_oid_fmt(&out, oid);
    return out;
}

pub fn oidShort(oid: *const c.git_oid) [7]u8 {
    return oidHex(oid)[0..7].*;
}

pub const Repo = struct {
    ptr: *c.git_repository,

    pub fn openDiscover(start: [*:0]const u8) GitError!Repo {
        var repo: ?*c.git_repository = null;
        try check(c.git_repository_open_ext(&repo, start, 0, null));
        return .{ .ptr = repo.? };
    }

    pub fn close(self: Repo) void {
        c.git_repository_free(self.ptr);
    }

    pub fn workdir(self: Repo) []const u8 {
        const w = c.git_repository_workdir(self.ptr) orelse return "";
        return std.mem.span(w);
    }

    pub fn gitdir(self: Repo) []const u8 {
        return std.mem.span(c.git_repository_path(self.ptr));
    }
};

const Collect = struct {
    arena: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
};

fn foreachCb(sm: ?*c.git_submodule, name: [*c]const u8, payload: ?*anyopaque) callconv(.c) c_int {
    _ = sm;
    const col: *Collect = @ptrCast(@alignCast(payload.?));
    const n = col.arena.dupe(u8, std.mem.span(name)) catch return -1;
    col.names.append(col.arena, n) catch return -1;
    return 0;
}

pub const Sub = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,
    branch: ?[]const u8,
    skip: bool,
    uninitialized: bool,
    detached: bool,
    dirty: bool,
    tracked_dirty: bool,
    gitlink_mismatch: bool,
    head: ?[7]u8,
    wd: ?[7]u8,
    head_oid: ?c.git_oid,
    wd_oid: ?c.git_oid,
    ref_name: ?[]const u8,
    ahead: usize = 0,
    behind: usize = 0,
    direct: bool,
};

fn flagsDirty(st: c_uint) bool {
    const wd_idx = @as(c_uint, 1) << 11;
    const wd_wd = @as(c_uint, 1) << 12;
    const wd_untracked = @as(c_uint, 1) << 13;
    const wd_mod = @as(c_uint, 1) << 10;
    return st & (wd_idx | wd_wd | wd_untracked | wd_mod) != 0;
}

fn flagsUninit(st: c_uint) bool {
    return st & (@as(c_uint, 1) << 7) != 0;
}

fn copyOptOid(oid: ?*const c.git_oid) ?c.git_oid {
    if (oid) |o| return o.*;
    return null;
}

fn fillSub(arena: std.mem.Allocator, repo: *c.git_repository, name: []const u8, path_prefix: []const u8) GitError!Sub {
    const name_z = try arena.dupeZ(u8, name);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);

    const path = std.mem.span(c.git_submodule_path(sm));
    const full_path = if (path_prefix.len == 0)
        try arena.dupe(u8, path)
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ path_prefix, path });

    const url_c = c.git_submodule_url(sm);
    const url = if (url_c) |u| try arena.dupe(u8, std.mem.span(u)) else "";
    const branch_c = c.git_submodule_branch(sm);
    const branch = if (branch_c) |b| try arena.dupe(u8, std.mem.span(b)) else null;

    const strategy = c.git_submodule_update_strategy(sm);
    const skip = strategy == c.GIT_SUBMODULE_UPDATE_NONE;

    var st: c_uint = 0;
    _ = c.git_submodule_status(&st, repo, name_z, c.GIT_SUBMODULE_IGNORE_UNSPECIFIED);

    const head_oid = copyOptOid(c.git_submodule_head_id(sm));
    const wd_oid = copyOptOid(c.git_submodule_wd_id(sm));

    var detached = false;
    var ref_name: ?[]const u8 = null;
    var tracked_dirty = false;
    var child: ?*c.git_repository = null;
    if (c.git_submodule_open(&child, sm) == 0) {
        defer c.git_repository_free(child);
        detached = c.git_repository_head_detached(child) == 1;
        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, child) == 0) {
            defer c.git_reference_free(head_ref);
            ref_name = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(head_ref)));
        }
        tracked_dirty = try hasTrackedChanges(child.?, true);
    }

    var mismatch = false;
    if (head_oid != null and wd_oid != null) {
        mismatch = c.git_oid_cmp(&head_oid.?, &wd_oid.?) != 0;
    } else if (head_oid != null and wd_oid == null) {
        mismatch = true;
    }

    var ahead: usize = 0;
    var behind: usize = 0;
    if (!flagsUninit(st)) {
        var child2: ?*c.git_repository = null;
        if (c.git_submodule_open(&child2, sm) == 0) {
            defer c.git_repository_free(child2);
            aheadBehind(child2.?, &ahead, &behind);
        }
    }

    return .{
        .name = try arena.dupe(u8, name),
        .path = full_path,
        .url = url,
        .branch = branch,
        .skip = skip,
        .uninitialized = flagsUninit(st),
        .detached = detached,
        .dirty = flagsDirty(st),
        .tracked_dirty = tracked_dirty,
        .gitlink_mismatch = mismatch,
        .head = if (head_oid) |o| oidShort(&o) else null,
        .wd = if (wd_oid) |o| oidShort(&o) else null,
        .head_oid = head_oid,
        .wd_oid = wd_oid,
        .ref_name = ref_name,
        .ahead = ahead,
        .behind = behind,
        .direct = path_prefix.len == 0,
    };
}

fn aheadBehind(repo: *c.git_repository, ahead: *usize, behind: *usize) void {
    var head: ?*c.git_reference = null;
    if (c.git_repository_head(&head, repo) != 0) return;
    defer c.git_reference_free(head);
    var upstream: ?*c.git_reference = null;
    if (c.git_branch_upstream(&upstream, head) != 0) return;
    defer c.git_reference_free(upstream);
    const local = c.git_reference_target(head) orelse return;
    const remote = c.git_reference_target(upstream) orelse return;
    var a: usize = 0;
    var b: usize = 0;
    if (c.git_graph_ahead_behind(&a, &b, repo, local, remote) == 0) {
        ahead.* = a;
        behind.* = b;
    }
}

pub fn listSubs(
    arena: std.mem.Allocator,
    repo: *c.git_repository,
    prefix: []const u8,
    recursive: bool,
    out: *std.ArrayList(Sub),
) GitError!void {
    var names: std.ArrayList([]const u8) = .empty;
    var col: Collect = .{ .arena = arena, .names = &names };
    try check(c.git_submodule_foreach(repo, foreachCb, &col));

    for (names.items) |name| {
        const sub = try fillSub(arena, repo, name, prefix);
        try out.append(arena, sub);
        if (recursive and !sub.uninitialized and !sub.skip) {
            const name_z = try arena.dupeZ(u8, name);
            var sm: ?*c.git_submodule = null;
            if (c.git_submodule_lookup(&sm, repo, name_z) != 0) continue;
            defer c.git_submodule_free(sm);
            var child: ?*c.git_repository = null;
            if (c.git_submodule_open(&child, sm) != 0) continue;
            defer c.git_repository_free(child);
            try listSubs(arena, child.?, sub.path, true, out);
        }
    }
}

pub fn parentDirty(repo: *c.git_repository) GitError!bool {
    var opts = std.mem.zeroes(c.git_status_options);
    try check(c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION));
    opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_EXCLUDE_SUBMODULES;
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &opts));
    defer c.git_status_list_free(list);
    return c.git_status_list_entrycount(list) > 0;
}

pub fn hasTrackedChanges(repo: *c.git_repository, exclude_submodules: bool) GitError!bool {
    var opts = std.mem.zeroes(c.git_status_options);
    try check(c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION));
    opts.flags = if (exclude_submodules) c.GIT_STATUS_OPT_EXCLUDE_SUBMODULES else 0;
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &opts));
    defer c.git_status_list_free(list);
    const n = c.git_status_list_entrycount(list);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = c.git_status_byindex(list, i);
        if (e == null) continue;
        const st = e.*.status;
        const tracked = st & (c.GIT_STATUS_INDEX_NEW | c.GIT_STATUS_INDEX_MODIFIED |
            c.GIT_STATUS_INDEX_DELETED | c.GIT_STATUS_INDEX_RENAMED | c.GIT_STATUS_INDEX_TYPECHANGE |
            c.GIT_STATUS_WT_MODIFIED | c.GIT_STATUS_WT_DELETED | c.GIT_STATUS_WT_TYPECHANGE |
            c.GIT_STATUS_WT_RENAMED);
        if (tracked != 0) return true;
    }
    return false;
}

pub fn headName(arena: std.mem.Allocator, repo: *c.git_repository) GitError![]const u8 {
    if (c.git_repository_head_detached(repo) == 1) return try arena.dupe(u8, "detached");
    var ref: ?*c.git_reference = null;
    try check(c.git_repository_head(&ref, repo));
    defer c.git_reference_free(ref);
    return try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(ref)));
}

pub fn headShort(repo: *c.git_repository) ?[7]u8 {
    var ref: ?*c.git_reference = null;
    if (c.git_repository_head(&ref, repo) != 0) return null;
    defer c.git_reference_free(ref);
    const oid = c.git_reference_target(ref) orelse return null;
    return oidShort(oid);
}

fn credCb(
    out: [*c]?*c.git_credential,
    url: [*c]const u8,
    username_from_url: [*c]const u8,
    allowed_types: c_uint,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    _ = url;
    _ = payload;
    const ssh = @as(c_uint, @intCast(c.GIT_CREDENTIAL_SSH_KEY));
    const def = @as(c_uint, @intCast(c.GIT_CREDENTIAL_DEFAULT));
    if (allowed_types & ssh != 0 and username_from_url != null) {
        return c.git_credential_ssh_key_from_agent(out, username_from_url);
    }
    if (allowed_types & def != 0) {
        return c.git_credential_default_new(out);
    }
    return -1;
}

fn fetchOpts() c.git_fetch_options {
    var opts = std.mem.zeroes(c.git_fetch_options);
    _ = c.git_fetch_options_init(&opts, c.GIT_FETCH_OPTIONS_VERSION);
    opts.callbacks.credentials = credCb;
    return opts;
}

pub fn fetchRemote(repo: *c.git_repository, name: [*:0]const u8) GitError!void {
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_lookup(&remote, repo, name));
    defer c.git_remote_free(remote);
    var opts = fetchOpts();
    try check(c.git_remote_fetch(remote, null, &opts, null));
}

pub fn syncSub(repo: *c.git_repository, name: []const u8, arena: std.mem.Allocator) GitError![]const u8 {
    const name_z = try arena.dupeZ(u8, name);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);

    var branch_name: ?[]const u8 = null;
    if (c.git_submodule_branch(sm)) |b| {
        branch_name = try arena.dupe(u8, std.mem.span(b));
    }

    var existing: ?*c.git_repository = null;
    if (c.git_submodule_open(&existing, sm) == 0) {
        defer c.git_repository_free(existing);
        if (branch_name == null and c.git_repository_head_detached(existing) == 0) {
            var head_ref: ?*c.git_reference = null;
            if (c.git_repository_head(&head_ref, existing) == 0) {
                defer c.git_reference_free(head_ref);
                branch_name = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(head_ref)));
            }
        }
    }

    var opts = std.mem.zeroes(c.git_submodule_update_options);
    try check(c.git_submodule_update_options_init(&opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION));
    try check(c.git_submodule_update(sm, 1, &opts));

    var child: ?*c.git_repository = null;
    try check(c.git_submodule_open(&child, sm));
    defer c.git_repository_free(child);

    const pin = c.git_submodule_wd_id(sm) orelse c.git_submodule_head_id(sm) orelse return error.Git;
    const attached = try attachAtPin(child.?, pin, branch_name, arena);
    return attached;
}

/// Point a local branch at `pin` and check it out. Never leaves HEAD detached.
/// Fast-forwards the branch if the pin is ahead; refuses to rewind.
fn attachAtPin(
    repo: *c.git_repository,
    pin: *const c.git_oid,
    preferred: ?[]const u8,
    arena: std.mem.Allocator,
) GitError![]const u8 {
    const name = preferred orelse (try findLocalBranchAt(repo, pin, arena)) orelse return error.WouldDetach;
    const name_z = try arena.dupeZ(u8, name);
    const refname_z = try std.fmt.allocPrintSentinel(arena, "refs/heads/{s}", .{name}, 0);

    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, pin));
    defer c.git_commit_free(commit);

    var branch: ?*c.git_reference = null;
    if (c.git_branch_lookup(&branch, repo, name_z, c.GIT_BRANCH_LOCAL) == 0) {
        defer c.git_reference_free(branch);
        const tip = c.git_reference_target(branch) orelse return error.Git;
        if (c.git_oid_cmp(tip, pin) != 0) {
            const pin_from_tip = c.git_graph_descendant_of(repo, pin, tip);
            if (pin_from_tip < 0) return error.Git;
            if (pin_from_tip == 0) {
                const tip_from_pin = c.git_graph_descendant_of(repo, tip, pin);
                if (tip_from_pin < 0) return error.Git;
                if (tip_from_pin == 1) return error.Ahead;
                return error.NotFastForward;
            }
            var new_ref: ?*c.git_reference = null;
            try check(c.git_reference_set_target(&new_ref, branch, pin, "rc sync: attach to gitlink"));
            defer c.git_reference_free(new_ref);
        }
    } else {
        var created: ?*c.git_reference = null;
        try check(c.git_branch_create(&created, repo, name_z, commit, 0));
        defer c.git_reference_free(created);
    }

    try check(c.git_repository_set_head(repo, refname_z));
    return name;
}

fn findLocalBranchAt(repo: *c.git_repository, pin: *const c.git_oid, arena: std.mem.Allocator) GitError!?[]const u8 {
    var iter: ?*c.git_branch_iterator = null;
    try check(c.git_branch_iterator_new(&iter, repo, c.GIT_BRANCH_LOCAL));
    defer c.git_branch_iterator_free(iter);

    var found_main: ?[]const u8 = null;
    var found_master: ?[]const u8 = null;
    var found_other: ?[]const u8 = null;

    while (true) {
        var ref: ?*c.git_reference = null;
        var kind: c.git_branch_t = undefined;
        const rc = c.git_branch_next(&ref, &kind, iter);
        if (rc != 0) break;
        defer c.git_reference_free(ref);
        const tip = c.git_reference_target(ref) orelse continue;
        if (c.git_oid_cmp(tip, pin) != 0) continue;
        const n = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(ref)));
        if (std.mem.eql(u8, n, "main")) found_main = n;
        if (std.mem.eql(u8, n, "master")) found_master = n;
        if (found_other == null) found_other = n;
    }

    return found_main orelse found_master orelse found_other;
}

pub fn addToIndex(repo: *c.git_repository, name: []const u8, arena: std.mem.Allocator) GitError!void {
    const name_z = try arena.dupeZ(u8, name);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);
    try check(c.git_submodule_add_to_index(sm, 1));
}

pub fn commitTracked(repo: *c.git_repository, message: [*:0]const u8, exclude_submodules: bool) GitError!bool {
    if (!try hasTrackedChanges(repo, exclude_submodules)) return false;

    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);

    var empty = std.mem.zeroes(c.git_strarray);
    try check(c.git_index_update_all(index, &empty, null, null));
    try check(c.git_index_write(index));

    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index));
    var tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&tree, repo, &tree_oid));
    defer c.git_tree_free(tree);

    var sig: ?*c.git_signature = null;
    try check(c.git_signature_default(&sig, repo));
    defer c.git_signature_free(sig);

    var parent: ?*c.git_commit = null;
    var parent_count: usize = 0;
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) == 0) {
        defer c.git_reference_free(head_ref);
        const oid = c.git_reference_target(head_ref);
        if (oid) |o| {
            try check(c.git_commit_lookup(&parent, repo, o));
            parent_count = 1;
        }
    }
    defer if (parent) |p| c.git_commit_free(p);

    var parents_buf: [1]?*const c.git_commit = .{null};
    var parents_ptr: [*c]?*const c.git_commit = null;
    if (parent) |p| {
        parents_buf[0] = p;
        parents_ptr = &parents_buf;
    }

    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(
        &commit_oid,
        repo,
        "HEAD",
        sig,
        sig,
        null,
        message,
        tree,
        parent_count,
        parents_ptr,
    ));
    return true;
}

pub fn lookupOidAfterFetch(repo: *c.git_repository, oid: *const c.git_oid) GitError!void {
    var obj: ?*c.git_object = null;
    const rc = c.git_object_lookup(&obj, repo, oid, c.GIT_OBJECT_COMMIT);
    if (rc == 0) {
        c.git_object_free(obj);
        return;
    }
    return error.Missing;
}

pub fn openSub(repo: *c.git_repository, name: []const u8, arena: std.mem.Allocator) GitError!Repo {
    const name_z = try arena.dupeZ(u8, name);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);
    var child: ?*c.git_repository = null;
    try check(c.git_submodule_open(&child, sm));
    return .{ .ptr = child.? };
}

pub fn ffPull(repo: *c.git_repository, ff_only: bool) GitError!void {
    var head: ?*c.git_reference = null;
    try check(c.git_repository_head(&head, repo));
    defer c.git_reference_free(head);

    var upstream: ?*c.git_reference = null;
    try check(c.git_branch_upstream(&upstream, head));

    try fetchRemote(repo, "origin");

    c.git_reference_free(upstream);
    upstream = null;
    try check(c.git_branch_upstream(&upstream, head));
    defer c.git_reference_free(upstream);

    const their_oid = c.git_reference_target(upstream) orelse return error.Git;
    var their: ?*c.git_annotated_commit = null;
    try check(c.git_annotated_commit_lookup(&their, repo, their_oid));
    defer c.git_annotated_commit_free(their);

    var analysis: c.git_merge_analysis_t = 0;
    var pref: c.git_merge_preference_t = 0;
    var heads = [_]*c.git_annotated_commit{their.?};
    try check(c.git_merge_analysis(&analysis, &pref, repo, @ptrCast(&heads), 1));

    const up_to_date = @as(c_uint, @intCast(c.GIT_MERGE_ANALYSIS_UP_TO_DATE));
    const ff = @as(c_uint, @intCast(c.GIT_MERGE_ANALYSIS_FASTFORWARD));
    const normal = @as(c_uint, @intCast(c.GIT_MERGE_ANALYSIS_NORMAL));
    const a = @as(c_uint, @intCast(analysis));

    if (a & up_to_date != 0) return;
    if (a & ff != 0) {
        var obj: ?*c.git_object = null;
        try check(c.git_object_lookup(&obj, repo, their_oid, c.GIT_OBJECT_COMMIT));
        defer c.git_object_free(obj);
        var new_ref: ?*c.git_reference = null;
        try check(c.git_reference_set_target(&new_ref, head, their_oid, "rc pull: fast-forward"));
        defer c.git_reference_free(new_ref);
        var copts = std.mem.zeroes(c.git_checkout_options);
        try check(c.git_checkout_options_init(&copts, c.GIT_CHECKOUT_OPTIONS_VERSION));
        try check(c.git_reset(repo, obj, c.GIT_RESET_HARD, &copts));
        return;
    }
    if (a & normal != 0) {
        if (ff_only) return error.NotFastForward;
        return error.NotFastForward; // first rip: never merge
    }
}

pub fn currentBranch(arena: std.mem.Allocator, repo: *c.git_repository) GitError![]const u8 {
    if (c.git_repository_head_detached(repo) == 1) return error.Detached;
    var ref: ?*c.git_reference = null;
    try check(c.git_repository_head(&ref, repo));
    defer c.git_reference_free(ref);
    return try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(ref)));
}

pub fn pushCurrent(repo: *c.git_repository, arena: std.mem.Allocator) GitError!void {
    const branch = try currentBranch(arena, repo);
    const spec = try std.fmt.allocPrintSentinel(arena, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch }, 0);
    var spec_ptr: [*:0]u8 = spec;
    var specs = c.git_strarray{
        .strings = @ptrCast(&spec_ptr),
        .count = 1,
    };
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_lookup(&remote, repo, "origin"));
    defer c.git_remote_free(remote);
    var opts = std.mem.zeroes(c.git_push_options);
    try check(c.git_push_options_init(&opts, c.GIT_PUSH_OPTIONS_VERSION));
    opts.callbacks.credentials = credCb;
    try check(c.git_remote_push(remote, &specs, &opts));
}

pub fn dieGit(app: *App, err: GitError) noreturn {
    switch (err) {
        error.Git => app.die("git: {s}", .{lastError()}),
        error.Detached => app.die("detached HEAD; check out a branch first", .{}),
        error.Dirty => app.die("dirty worktree; commit or clean before continuing", .{}),
        error.NotFastForward => app.die("not a fast-forward (ff-only)", .{}),
        error.Missing => app.die("gitlink SHA missing on remote", .{}),
        error.Uncommitted => app.die("uncommitted changes; commit first", .{}),
        error.NoTty => app.die("no TTY and no -m; pass -m or run in a terminal", .{}),
        error.Aborted => app.die("abort: empty commit message", .{}),
        error.NothingToCommit => app.die("nothing to commit", .{}),
        error.WouldDetach => app.die("would detach HEAD; set branch= in .gitmodules", .{}),
        error.Ahead => app.die("local branch is ahead of the recorded gitlink; rc commit first", .{}),
        error.OutOfMemory => app.die("out of memory", .{}),
    }
}

const std = @import("std");
const c = @import("git2");
const App = @import("app.zig").App;

pub const GitError = error{
    Git,
    OutOfMemory,
    Detached,
    Dirty,
    NotFastForward,
    Missing,
    Uncommitted,
    NoTty,
    Aborted,
    NothingToCommit,
    WouldDetach,
    Ahead,
    NoUpstream,
    NoIdentity,
    Uninitialized,
    UnknownPath,
    AmbiguousPath,
    StagedOutside,
};

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

pub const Repository = c.git_repository;

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
    /// Path of the repo that contains this submodule. Empty for children of the project root.
    parent_path: []const u8,
    untracked: bool,
};

fn flagsUninit(st: c_uint) bool {
    return (st & @as(c_uint, @intCast(c.GIT_SUBMODULE_STATUS_WD_UNINITIALIZED))) != 0;
}

fn copyOptOid(oid: ?*const c.git_oid) ?c.git_oid {
    if (oid) |o| return o.*;
    return null;
}

fn fillSub(arena: std.mem.Allocator, repo: *c.git_repository, name: []const u8, path_prefix: []const u8) GitError!Sub {
    const name_z = try arena.dupeSentinel(u8, name, 0);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);

    const path = std.mem.span(c.git_submodule_path(sm));
    const full_path = if (path_prefix.len == 0)
        try arena.dupe(u8, path)
    else
        try arena.print("{s}/{s}", .{ path_prefix, path });

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
        .dirty = tracked_dirty,
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
        .parent_path = try arena.dupe(u8, path_prefix),
        .untracked = (st & @as(c_uint, @intCast(c.GIT_SUBMODULE_STATUS_WD_UNTRACKED))) != 0,
    };
}

pub fn aheadBehind(repo: *c.git_repository, ahead: *usize, behind: *usize) void {
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
            const name_z = try arena.dupeSentinel(u8, name, 0);
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
    return hasTrackedChanges(repo, true);
}

pub fn parentUntracked(repo: *c.git_repository) GitError!bool {
    var opts = std.mem.zeroes(c.git_status_options);
    try check(c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION));
    opts.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_EXCLUDE_SUBMODULES;
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &opts));
    defer c.git_status_list_free(list);
    const n = c.git_status_list_entrycount(list);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = c.git_status_byindex(list, i);
        if (e == null) continue;
        if ((e.*.status & @as(c_uint, @intCast(c.GIT_STATUS_WT_NEW))) != 0) return true;
    }
    return false;
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
    if (c.git_repository_head_unborn(repo) == 1) return try arena.dupe(u8, "unborn");
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
    if ((allowed_types & ssh) != 0 and username_from_url != null) {
        return c.git_credential_ssh_key_from_agent(out, username_from_url);
    }
    if ((allowed_types & def) != 0) {
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
    const name_z = try arena.dupeSentinel(u8, name, 0);
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
        if (c.git_submodule_head_id(sm)) |pin| {
            _ = try classifyAttach(existing.?, pin, branch_name, arena);
        }
    } else if (branch_name == null and c.git_submodule_head_id(sm) != null) {
        return error.WouldDetach;
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

/// Decide whether `pin` can be attached without moving any ref.
/// A missing commit object is not a refusal: the caller may still fetch it.
pub fn classifyAttach(
    repo: *c.git_repository,
    pin: *const c.git_oid,
    preferred: ?[]const u8,
    arena: std.mem.Allocator,
) GitError![]const u8 {
    const name = preferred orelse (try findLocalBranchAt(repo, pin, arena)) orelse return error.WouldDetach;
    const name_z = try arena.dupeSentinel(u8, name, 0);
    var branch: ?*c.git_reference = null;
    if (c.git_branch_lookup(&branch, repo, name_z, c.GIT_BRANCH_LOCAL) != 0) return name;
    defer c.git_reference_free(branch);
    const tip = c.git_reference_target(branch) orelse return error.Git;
    if (c.git_oid_cmp(tip, pin) == 0) return name;

    const pin_ahead = c.git_graph_descendant_of(repo, pin, tip);
    if (pin_ahead == c.GIT_ENOTFOUND) return name;
    if (pin_ahead < 0) return error.Git;
    if (pin_ahead == 1) return name;

    const tip_ahead = c.git_graph_descendant_of(repo, tip, pin);
    if (tip_ahead == c.GIT_ENOTFOUND) return name;
    if (tip_ahead < 0) return error.Git;
    if (tip_ahead == 1) return error.Ahead;
    return error.NotFastForward;
}

/// Point a local branch at `pin` and check it out. Never leaves HEAD detached.
/// Fast-forwards the branch if the pin is ahead; refuses to rewind.
fn attachAtPin(
    repo: *c.git_repository,
    pin: *const c.git_oid,
    preferred: ?[]const u8,
    arena: std.mem.Allocator,
) GitError![]const u8 {
    const name = try classifyAttach(repo, pin, preferred, arena);
    const name_z = try arena.dupeSentinel(u8, name, 0);
    const refname_z = try arena.printSentinel("refs/heads/{s}", .{name}, 0);

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
            try check(c.git_reference_set_target(&new_ref, branch, pin, "rc update: attach to gitlink"));
            defer c.git_reference_free(new_ref);
        }
    } else {
        var created: ?*c.git_reference = null;
        try check(c.git_branch_create(&created, repo, name_z, commit, 0));
        defer c.git_reference_free(created);
    }

    try check(c.git_repository_set_head(repo, refname_z));
    var copts = std.mem.zeroes(c.git_checkout_options);
    try check(c.git_checkout_options_init(&copts, c.GIT_CHECKOUT_OPTIONS_VERSION));
    try check(c.git_checkout_head(repo, &copts));
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
    const name_z = try arena.dupeSentinel(u8, name, 0);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);
    try check(c.git_submodule_add_to_index(sm, 1));
}

pub fn commitTracked(repo: *c.git_repository, message: [*:0]const u8, update_worktree: bool) GitError!bool {
    if (update_worktree and try hasTrackedChanges(repo, true)) {
        if (c.git_repository_head_detached(repo) == 1) return error.Detached;
        try requireIdentity(repo);
    }
    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);

    if (update_worktree) {
        var empty = std.mem.zeroes(c.git_strarray);
        try check(c.git_index_update_all(index, &empty, null, null));
        try check(c.git_index_write(index));
    }

    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index));

    var parent: ?*c.git_commit = null;
    defer if (parent) |p| c.git_commit_free(p);
    var parent_count: usize = 0;
    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head(&head_ref, repo) == 0) {
        defer c.git_reference_free(head_ref);
        const oid = c.git_reference_target(head_ref);
        if (oid) |o| {
            try check(c.git_commit_lookup(&parent, repo, o));
            parent_count = 1;
            const head_tree = c.git_commit_tree_id(parent);
            if (c.git_oid_equal(&tree_oid, head_tree) == 1) return false;
        }
    }

    if (c.git_repository_head_detached(repo) == 1) return error.Detached;

    var sig: ?*c.git_signature = null;
    const sig_rc = c.git_signature_default(&sig, repo);
    if (sig_rc < 0) {
        if (sig_rc == c.GIT_ENOTFOUND) return error.NoIdentity;
        return error.Git;
    }
    defer c.git_signature_free(sig);

    var tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&tree, repo, &tree_oid));
    defer c.git_tree_free(tree);

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

fn requireIdentity(repo: *c.git_repository) GitError!void {
    var sig: ?*c.git_signature = null;
    const sig_rc = c.git_signature_default(&sig, repo);
    if (sig_rc < 0) {
        if (sig_rc == c.GIT_ENOTFOUND) return error.NoIdentity;
        return error.Git;
    }
    c.git_signature_free(sig);
}

/// Path-limited commits may stage gitlinks and nothing else.
pub fn refuseForeignStaged(repo: *c.git_repository, allowed: []const []const u8) GitError!void {
    var opts = std.mem.zeroes(c.git_status_options);
    try check(c.git_status_options_init(&opts, c.GIT_STATUS_OPTIONS_VERSION));
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &opts));
    defer c.git_status_list_free(list);
    const n = c.git_status_list_entrycount(list);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_status_byindex(list, i) orelse continue;
        const staged = entry.*.status & (c.GIT_STATUS_INDEX_NEW | c.GIT_STATUS_INDEX_MODIFIED |
            c.GIT_STATUS_INDEX_DELETED | c.GIT_STATUS_INDEX_RENAMED | c.GIT_STATUS_INDEX_TYPECHANGE);
        if (staged == 0) continue;
        const delta = entry.*.head_to_index orelse return error.StagedOutside;
        const path_c = delta.*.new_file.path orelse delta.*.old_file.path orelse return error.StagedOutside;
        const path = std.mem.span(path_c);
        var ok = false;
        for (allowed) |allowed_path| {
            if (std.mem.eql(u8, allowed_path, path)) ok = true;
        }
        if (!ok) return error.StagedOutside;
    }
}

pub fn oidOnRemote(repo: *c.git_repository, oid: *const c.git_oid) bool {
    var iter: ?*c.git_reference_iterator = null;
    if (c.git_reference_iterator_glob_new(&iter, repo, "refs/remotes/*") != 0) return false;
    defer c.git_reference_iterator_free(iter);
    while (true) {
        var ref: ?*c.git_reference = null;
        if (c.git_reference_next(&ref, iter) != 0) break;
        defer c.git_reference_free(ref);
        const tip = c.git_reference_target(ref) orelse continue;
        if (c.git_oid_cmp(tip, oid) == 0) return true;
        if (c.git_graph_descendant_of(repo, tip, oid) == 1) return true;
    }
    return false;
}

pub fn openSub(repo: *c.git_repository, name: []const u8, arena: std.mem.Allocator) GitError!Repo {
    const name_z = try arena.dupeSentinel(u8, name, 0);
    var sm: ?*c.git_submodule = null;
    try check(c.git_submodule_lookup(&sm, repo, name_z));
    defer c.git_submodule_free(sm);
    var child: ?*c.git_repository = null;
    try check(c.git_submodule_open(&child, sm));
    return .{ .ptr = child.? };
}

pub const FastForward = struct {
    /// Null when the branch already contains the upstream. Otherwise the commit to reset onto.
    target: ?c.git_oid = null,
};

/// Fetch the upstream and classify. Does not move HEAD.
pub fn ffPrepare(repo: *c.git_repository, arena: std.mem.Allocator, ff_only: bool) GitError!FastForward {
    if (!ff_only) return error.NotFastForward;
    if (c.git_repository_head_detached(repo) == 1) return error.Detached;
    var head: ?*c.git_reference = null;
    try check(c.git_repository_head(&head, repo));
    defer c.git_reference_free(head);

    var upstream: ?*c.git_reference = null;
    if (c.git_branch_upstream(&upstream, head) != 0) return error.NoUpstream;
    const remote_name = try remoteFromTracking(upstream, arena);
    c.git_reference_free(upstream);

    try fetchRemote(repo, remote_name);

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
    const a = @as(c_uint, @intCast(analysis));

    if ((a & up_to_date) != 0) return .{};
    if ((a & ff) != 0) return .{ .target = their_oid.* };
    return error.NotFastForward;
}

pub fn ffApply(repo: *c.git_repository, target: c.git_oid) GitError!void {
    var head: ?*c.git_reference = null;
    try check(c.git_repository_head(&head, repo));
    defer c.git_reference_free(head);
    var obj: ?*c.git_object = null;
    try check(c.git_object_lookup(&obj, repo, &target, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(obj);
    var new_ref: ?*c.git_reference = null;
    try check(c.git_reference_set_target(&new_ref, head, &target, "rc pull: fast-forward"));
    defer c.git_reference_free(new_ref);
    var copts = std.mem.zeroes(c.git_checkout_options);
    try check(c.git_checkout_options_init(&copts, c.GIT_CHECKOUT_OPTIONS_VERSION));
    try check(c.git_reset(repo, obj, c.GIT_RESET_HARD, &copts));
}

/// Refuse to fast-forward `repo` onto `oid` when a nested branch cannot attach to the gitlink that commit records.
pub fn preflightTree(
    app: *App,
    arena: std.mem.Allocator,
    repo: *c.git_repository,
    oid: *const c.git_oid,
    prefix: []const u8,
) GitError!void {
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, oid));
    defer c.git_commit_free(commit);
    var tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&tree, commit));
    defer c.git_tree_free(tree);

    const n = c.git_tree_entrycount(tree);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_tree_entry_byindex(tree, i) orelse continue;
        if (c.git_tree_entry_filemode(entry) != @as(c_uint, @intCast(c.GIT_FILEMODE_COMMIT))) continue;
        const name = std.mem.span(c.git_tree_entry_name(entry));
        const pin = c.git_tree_entry_id(entry) orelse continue;
        const full = if (prefix.len == 0)
            try arena.dupe(u8, name)
        else
            try arena.print("{s}/{s}", .{ prefix, name });

        const name_z = try arena.dupeSentinel(u8, name, 0);
        var sm: ?*c.git_submodule = null;
        if (c.git_submodule_lookup(&sm, repo, name_z) != 0) continue;
        defer c.git_submodule_free(sm);
        if (c.git_submodule_update_strategy(sm) == c.GIT_SUBMODULE_UPDATE_NONE) continue;

        var branch: ?[]const u8 = null;
        if (c.git_submodule_branch(sm)) |b| branch = try arena.dupe(u8, std.mem.span(b));

        var child: ?*c.git_repository = null;
        if (c.git_submodule_open(&child, sm) != 0) continue;
        defer c.git_repository_free(child);
        _ = classifyAttach(child.?, pin, branch, arena) catch |e| fail(app, full, e);
        var nested: ?*c.git_commit = null;
        if (c.git_commit_lookup(&nested, child.?, pin) == 0) {
            c.git_commit_free(nested);
            try preflightTree(app, arena, child.?, pin, full);
        }
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
    if (c.git_repository_head_detached(repo) == 1) return error.Detached;
    const branch = try currentBranch(arena, repo);
    var head: ?*c.git_reference = null;
    try check(c.git_repository_head(&head, repo));
    defer c.git_reference_free(head);
    var upstream: ?*c.git_reference = null;
    if (c.git_branch_upstream(&upstream, head) != 0) return error.NoUpstream;
    defer c.git_reference_free(upstream);
    const remote_name = try remoteFromTracking(upstream, arena);
    const upstream_branch = try branchFromTracking(upstream);

    const spec = try arena.printSentinel("refs/heads/{s}:refs/heads/{s}", .{ branch, upstream_branch }, 0);
    var spec_ptr: [*:0]u8 = spec;
    var specs = c.git_strarray{
        .strings = @ptrCast(&spec_ptr),
        .count = 1,
    };
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_lookup(&remote, repo, remote_name));
    defer c.git_remote_free(remote);
    var opts = std.mem.zeroes(c.git_push_options);
    try check(c.git_push_options_init(&opts, c.GIT_PUSH_OPTIONS_VERSION));
    opts.callbacks.credentials = credCb;
    try check(c.git_remote_push(remote, &specs, &opts));
}

pub fn dieGit(app: *App, err: GitError) noreturn {
    fail(app, "", err);
}

pub fn fail(app: *App, where: []const u8, err: GitError) noreturn {
    const msg: []const u8 = switch (err) {
        error.Git => lastError(),
        error.Detached => "detached HEAD; run rc update to attach a branch",
        error.Dirty => "tracked changes; commit or clean before continuing",
        error.NotFastForward => "not a fast-forward (ff-only)",
        error.Missing => "gitlink SHA missing on remote",
        error.Uncommitted => "uncommitted changes; commit first",
        error.NoTty => "no TTY and no -m; pass -m or run in a terminal",
        error.Aborted => "abort: empty commit message",
        error.NothingToCommit => "nothing to commit",
        error.WouldDetach => "would detach HEAD; set branch= in .gitmodules",
        error.Ahead => "local branch is ahead of the recorded gitlink; rc commit first",
        error.NoUpstream => "no upstream; set a remote tracking branch",
        error.NoIdentity => "set user.name and user.email",
        error.Uninitialized => "uninitialized; run rc update",
        error.UnknownPath => "unknown submodule",
        error.AmbiguousPath => "ambiguous submodule path",
        error.StagedOutside => "staged changes outside this path",
        error.OutOfMemory => "out of memory",
    };
    if (where.len == 0) app.die("{s}", .{msg});
    app.die("{s}: {s}", .{ where, msg });
}

pub const Opened = struct {
    owned: ?Repo = null,
    ptr: *c.git_repository,
    name: []const u8 = "",

    pub fn close(self: Opened) void {
        if (self.owned) |r| r.close();
    }
};

pub fn openParent(root: *c.git_repository, sub: Sub, arena: std.mem.Allocator) GitError!Opened {
    if (sub.parent_path.len == 0) return .{ .ptr = root, .name = sub.name };
    const parent = try openByPath(root, sub.parent_path, arena);
    return .{ .owned = parent, .ptr = parent.ptr, .name = sub.name };
}

pub fn openByPath(root: *c.git_repository, full_path: []const u8, arena: std.mem.Allocator) GitError!Repo {
    var current = root;
    var opened: ?Repo = null;
    errdefer if (opened) |r| r.close();
    var rest = full_path;
    while (rest.len > 0) {
        const step = try longestPrefixSub(current, rest, arena);
        const child = try openSub(current, step.name, arena);
        if (opened) |prev| prev.close();
        opened = child;
        current = child.ptr;
        if (step.path.len == rest.len) return child;
        rest = rest[step.path.len + 1 ..];
    }
    return error.Missing;
}

const Step = struct { name: []const u8, path: []const u8 };

fn longestPrefixSub(repo: *c.git_repository, rest: []const u8, arena: std.mem.Allocator) GitError!Step {
    var names: std.ArrayList([]const u8) = .empty;
    var col: Collect = .{ .arena = arena, .names = &names };
    try check(c.git_submodule_foreach(repo, foreachCb, &col));

    var best: ?Step = null;
    for (names.items) |name| {
        const name_z = try arena.dupeSentinel(u8, name, 0);
        var sm: ?*c.git_submodule = null;
        if (c.git_submodule_lookup(&sm, repo, name_z) != 0) continue;
        defer c.git_submodule_free(sm);
        const path = std.mem.span(c.git_submodule_path(sm));
        const eq = std.mem.eql(u8, rest, path);
        const pref = rest.len > path.len and std.mem.startsWith(u8, rest, path) and rest[path.len] == '/';
        if (!eq and !pref) continue;
        if (best == null or path.len > best.?.path.len) {
            best = .{
                .name = try arena.dupe(u8, name),
                .path = try arena.dupe(u8, path),
            };
        }
    }
    return best orelse error.Missing;
}

fn remoteFromTracking(upstream: ?*c.git_reference, arena: std.mem.Allocator) GitError![:0]const u8 {
    const rest = try trackingRest(upstream);
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoUpstream;
    if (slash == 0 or slash + 1 >= rest.len) return error.NoUpstream;
    return arena.printSentinel("{s}", .{rest[0..slash]}, 0);
}

fn branchFromTracking(upstream: ?*c.git_reference) GitError![]const u8 {
    const rest = try trackingRest(upstream);
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoUpstream;
    if (slash == 0 or slash + 1 >= rest.len) return error.NoUpstream;
    return rest[slash + 1 ..];
}

fn trackingRest(upstream: ?*c.git_reference) GitError![]const u8 {
    const name = std.mem.span(c.git_reference_name(upstream));
    const prefix = "refs/remotes/";
    if (!std.mem.startsWith(u8, name, prefix)) return error.NoUpstream;
    return name[prefix.len..];
}

pub fn sortDeepest(subs: []Sub) void {
    std.mem.sort(Sub, subs, {}, struct {
        fn lessThan(_: void, a: Sub, b: Sub) bool {
            const da = pathDepth(a.path);
            const db = pathDepth(b.path);
            if (da != db) return da > db;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

pub fn sortShallowest(subs: []Sub) void {
    std.mem.sort(Sub, subs, {}, struct {
        fn lessThan(_: void, a: Sub, b: Sub) bool {
            const da = pathDepth(a.path);
            const db = pathDepth(b.path);
            if (da != db) return da < db;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn pathDepth(path: []const u8) usize {
    if (path.len == 0) return 0;
    var n: usize = 1;
    for (path) |ch| {
        if (ch == '/') n += 1;
    }
    return n;
}

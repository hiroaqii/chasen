const std = @import("std");

/// Identity of one accepted start. Never reused within a Requests/run.
pub const WatchRequestId = enum(u64) { _ };
pub const WatchExclusion = union(enum) { exact: []const u8, subtree: []const u8 };
pub const WatchOptions = struct {
    /// Directory root. Watch a file by selecting its name in the parent directory.
    path: []const u8,
    recursive: bool = true,
    select: ?[]const u8 = null,
    exclude: []const WatchExclusion = &.{},
};
pub const WatchFailure = enum {
    unsupported,
    path_not_found,
    not_directory,
    access_denied,
    out_of_memory,
    resource_limit,
    worker_unavailable,
    io_failure,
    root_lost,
    overflow,
    coverage_lost,
};
pub const WatchOutcome = union(enum) {
    ready,
    changed,
    rescan,
    failed: WatchFailure,
};
/// Non-owning value. Path and application metadata remain outside the notice.
pub const WatchNotice = struct {
    id: u64,
    request_id: WatchRequestId,
    outcome: WatchOutcome,
};

pub const max_path_bytes = 4095;
pub const max_depth = 64;
pub const max_exclusions = 16;
const max_input_bytes = 16 * 1024;

/// Internal copied input. Slice fields point into storage, never into this
/// struct, so transfer from pending storage to a stable live node is safe.
pub const OwnedInput = struct {
    storage: []u8,
    path: []const u8,
    recursive: bool,
    select: ?[]const u8,
    exclusions: [max_exclusions]WatchExclusion = undefined,
    exclusions_len: usize,

    pub const Error = error{ InvalidWatchOptions, WatchResourceLimitExceeded } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, options: WatchOptions) Error!OwnedInput {
        try validatePath(options.path, false);
        if (options.exclude.len > max_exclusions) return error.WatchResourceLimitExceeded;
        var size = options.path.len;
        if (options.select) |path| {
            try validatePath(path, true);
            if (!options.recursive and std.mem.indexOfScalar(u8, path, '/') != null)
                return error.InvalidWatchOptions;
            size += path.len;
        }
        for (options.exclude) |rule| {
            const path = switch (rule) {
                inline else => |p| p,
            };
            try validatePath(path, true);
            size += path.len;
        }
        if (size > max_input_bytes) return error.WatchResourceLimitExceeded;
        const storage = try allocator.alloc(u8, size);
        var offset: usize = 0;
        var result: OwnedInput = .{
            .storage = storage,
            .path = copy(storage, &offset, options.path),
            .recursive = options.recursive,
            .select = if (options.select) |path| copy(storage, &offset, path) else null,
            .exclusions_len = options.exclude.len,
        };
        for (options.exclude, 0..) |rule, i| result.exclusions[i] = switch (rule) {
            .exact => |path| .{ .exact = copy(storage, &offset, path) },
            .subtree => |path| .{ .subtree = copy(storage, &offset, path) },
        };
        return result;
    }

    pub fn deinit(self: *OwnedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    /// Only for a precise relative entry. Coarse/identity/coverage events must
    /// bypass this filter and publish rescan or terminal failure instead.
    pub fn selected(self: *const OwnedInput, path: []const u8) bool {
        if (self.select) |selection| if (!std.mem.eql(u8, path, selection)) return false;
        for (self.exclusions[0..self.exclusions_len]) |rule| switch (rule) {
            .exact => |excluded| if (std.mem.eql(u8, path, excluded)) return false,
            .subtree => |excluded| if (within(path, excluded)) return false,
        };
        return true;
    }
};

pub fn within(path: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, path, parent) or
        (path.len > parent.len and path[parent.len] == '/' and std.mem.startsWith(u8, path, parent));
}

fn copy(storage: []u8, offset: *usize, input: []const u8) []const u8 {
    const out = storage[offset.*..][0..input.len];
    @memcpy(out, input);
    offset.* += input.len;
    return out;
}

fn validatePath(path: []const u8, relative: bool) OwnedInput.Error!void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidWatchOptions;
    if (path.len > max_path_bytes) return error.WatchResourceLimitExceeded;
    if (relative and path[0] == '/') return error.InvalidWatchOptions;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (relative and (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")))
            return error.InvalidWatchOptions;
        if (part.len != 0) depth += 1;
    }
    if (depth > max_depth) return error.WatchResourceLimitExceeded;
}

test "watch copies options and filters exact entries at component boundaries" {
    var root = [_]u8{ 't', 'm', 'p' };
    var rule = [_]u8{ 'b', 'i', 'n' };
    var input = try OwnedInput.init(std.testing.allocator, .{
        .path = &root,
        .exclude = &.{ .{ .exact = "file" }, .{ .subtree = &rule } },
    });
    defer input.deinit(std.testing.allocator);
    root[0] = 'x';
    rule[0] = 'x';
    try std.testing.expectEqualStrings("tmp", input.path);
    try std.testing.expect(!input.selected("file"));
    try std.testing.expect(input.selected("file/child"));
    try std.testing.expect(!input.selected("bin"));
    try std.testing.expect(!input.selected("bin/child"));
    try std.testing.expect(input.selected("binary/child"));
    var selected = try OwnedInput.init(std.testing.allocator, .{ .path = ".", .select = "dir/file" });
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected.selected("dir/file"));
    try std.testing.expect(!selected.selected("dir/file2"));
}

test "watch rejects ambiguous rules and finite input limit violations" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "/file", "./file", "a/../b", "a//b", "a/", "a\x00b" }) |rule|
        try std.testing.expectError(error.InvalidWatchOptions, OwnedInput.init(allocator, .{ .path = ".", .select = rule }));
    try std.testing.expectError(error.InvalidWatchOptions, OwnedInput.init(allocator, .{ .path = "" }));
    try std.testing.expectError(error.InvalidWatchOptions, OwnedInput.init(allocator, .{ .path = ".", .recursive = false, .select = "a/b" }));
    const long_path: [max_path_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.WatchResourceLimitExceeded, OwnedInput.init(allocator, .{ .path = &long_path }));
    const rules: [max_exclusions + 1]WatchExclusion = @splat(.{ .exact = "x" });
    try std.testing.expectError(error.WatchResourceLimitExceeded, OwnedInput.init(allocator, .{ .path = ".", .exclude = &rules }));
    const long_rules: [5]WatchExclusion = @splat(.{ .exact = long_path[0..max_path_bytes] });
    try std.testing.expectError(error.WatchResourceLimitExceeded, OwnedInput.init(allocator, .{ .path = ".", .exclude = &long_rules }));
    var deep: [max_depth * 2 + 1]u8 = undefined;
    for (&deep, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'x' else '/';
    try std.testing.expectError(error.WatchResourceLimitExceeded, OwnedInput.init(allocator, .{ .path = &deep }));
}

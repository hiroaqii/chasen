const std = @import("std");

pub const ComponentStateInitContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
};

pub const ComponentStateDeinitContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
};

const StoredState = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    deinit_fn: ?*const fn (*anyopaque, ComponentStateDeinitContext) void,
};

/// Arena-backed retained visual state for reusable components.
///
/// This is for component-local UI state such as scroll offsets, animation
/// phase, cursor viewport, or selection anchors. It is not intended for app
/// domain state, persisted data, or high-churn caches.
///
/// `remove` and `clearNamespace` call stored `deinit` hooks and remove map
/// entries, but they do not reclaim arena memory. Memory is reclaimed when the
/// whole store is deinitialized.
pub const ComponentStateStore = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap(StoredState),
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) ComponentStateStore {
        return initWithIo(allocator, null);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: ?std.Io) ComponentStateStore {
        return .{
            .backing_allocator = allocator,
            .arena = .init(allocator),
            .map = .init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *ComponentStateStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.deinitStored(entry.value_ptr.*);
        }
        self.map.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getOrCreate(
        self: *ComponentStateStore,
        id: []const u8,
        comptime T: type,
        init_fn: *const fn (ComponentStateInitContext) anyerror!T,
    ) !*T {
        if (self.map.getPtr(id)) |stored| {
            self.assertType(T, stored.*);
            return typedPtr(T, stored.ptr);
        }

        const allocator = self.arena.allocator();
        try self.map.ensureUnusedCapacity(1);

        const id_copy = try allocator.dupe(u8, id);
        const ptr = try allocator.create(T);
        errdefer allocator.destroy(ptr);

        ptr.* = try init_fn(.{
            .allocator = allocator,
            .io = self.io,
        });
        errdefer self.deinitStored(.{
            .ptr = ptr,
            .type_name = typeName(T),
            .deinit_fn = deinitFn(T),
        });

        self.map.putAssumeCapacity(id_copy, .{
            .ptr = ptr,
            .type_name = typeName(T),
            .deinit_fn = deinitFn(T),
        });
        return ptr;
    }

    pub fn get(self: *ComponentStateStore, id: []const u8, comptime T: type) ?*T {
        const stored = self.map.get(id) orelse return null;
        self.assertType(T, stored);
        return typedPtr(T, stored.ptr);
    }

    pub fn remove(self: *ComponentStateStore, id: []const u8) void {
        if (self.map.fetchRemove(id)) |kv| {
            self.deinitStored(kv.value);
        }
    }

    pub fn clearNamespace(self: *ComponentStateStore, prefix: []const u8) void {
        var matching_keys: [32][]const u8 = undefined;

        while (true) {
            var matching_count: usize = 0;
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, prefix)) {
                    matching_keys[matching_count] = key;
                    matching_count += 1;
                    if (matching_count == matching_keys.len) break;
                }
            }

            // Keys are arena-owned and remove() does not reclaim arena memory,
            // so collected key slices remain valid after iteration ends.
            for (matching_keys[0..matching_count]) |id| {
                self.remove(id);
            }

            if (matching_count < matching_keys.len) break;
        }
    }

    pub fn count(self: *const ComponentStateStore) usize {
        return self.map.count();
    }

    fn deinitStored(self: *ComponentStateStore, stored: StoredState) void {
        if (stored.deinit_fn) |deinit_fn| {
            deinit_fn(stored.ptr, .{
                .allocator = self.arena.allocator(),
                .io = self.io,
            });
        }
    }

    fn assertType(self: *ComponentStateStore, comptime T: type, stored: StoredState) void {
        _ = self;
        const expected = typeName(T);
        if (!std.mem.eql(u8, stored.type_name, expected)) {
            std.debug.panic(
                "ComponentStateStore type mismatch: requested {s}, stored {s}",
                .{ expected, stored.type_name },
            );
        }
    }
};

fn typeName(comptime T: type) []const u8 {
    return @typeName(T);
}

fn typedPtr(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

fn deinitFn(comptime T: type) ?*const fn (*anyopaque, ComponentStateDeinitContext) void {
    if (!@hasDecl(T, "deinit")) return null;

    return struct {
        fn call(ptr: *anyopaque, ctx: ComponentStateDeinitContext) void {
            const typed = typedPtr(T, ptr);
            typed.deinit(ctx);
        }
    }.call;
}

test "ComponentStateStore getOrCreate creates and reuses state" {
    const State = struct {
        value: u32,

        fn init(_: ComponentStateInitContext) !@This() {
            return .{ .value = 1 };
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.getOrCreate("counter", State, State.init);
    try std.testing.expectEqual(@as(u32, 1), first.value);
    first.value = 42;

    const second = try store.getOrCreate("counter", State, State.init);
    try std.testing.expectEqual(@as(u32, 42), second.value);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "ComponentStateStore get returns null for missing id" {
    const State = struct { value: u32 };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(store.get("missing", State) == null);
}

test "ComponentStateStore remove calls deinit and removes entry" {
    const State = struct {
        counter: *u32,

        fn init(ctx: ComponentStateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: ComponentStateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    const state = try store.getOrCreate("state", State, State.init);
    const counter = state.counter;

    store.remove("state");

    try std.testing.expectEqual(@as(u32, 1), counter.*);
    try std.testing.expect(store.get("state", State) == null);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "ComponentStateStore clearNamespace removes matching entries" {
    const State = struct {
        counter: *u32,

        fn init(ctx: ComponentStateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: ComponentStateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    const a = try store.getOrCreate("screen/a", State, State.init);
    const b = try store.getOrCreate("screen/b", State, State.init);
    _ = try store.getOrCreate("other/c", State, State.init);

    const a_counter = a.counter;
    const b_counter = b.counter;

    store.clearNamespace("screen/");

    try std.testing.expectEqual(@as(u32, 1), a_counter.*);
    try std.testing.expectEqual(@as(u32, 1), b_counter.*);
    try std.testing.expect(store.get("screen/a", State) == null);
    try std.testing.expect(store.get("screen/b", State) == null);
    try std.testing.expect(store.get("other/c", State) != null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "ComponentStateStore clearNamespace leaves store unchanged when no ids match" {
    const State = struct {
        value: u32,

        fn init(_: ComponentStateInitContext) !@This() {
            return .{ .value = 1 };
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.getOrCreate("screen/a", State, State.init);
    _ = try store.getOrCreate("other/b", State, State.init);

    store.clearNamespace("missing/");

    try std.testing.expect(store.get("screen/a", State) != null);
    try std.testing.expect(store.get("other/b", State) != null);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "ComponentStateStore clearNamespace empty prefix clears all entries" {
    const State = struct {
        counter: *u32,

        fn init(ctx: ComponentStateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: ComponentStateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    const a = try store.getOrCreate("screen/a", State, State.init);
    const b = try store.getOrCreate("other/b", State, State.init);
    const a_counter = a.counter;
    const b_counter = b.counter;

    store.clearNamespace("");

    try std.testing.expectEqual(@as(u32, 1), a_counter.*);
    try std.testing.expectEqual(@as(u32, 1), b_counter.*);
    try std.testing.expect(store.get("screen/a", State) == null);
    try std.testing.expect(store.get("other/b", State) == null);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "ComponentStateStore clearNamespace removes more entries than one chunk" {
    const State = struct {
        counter: *u32,

        fn init(ctx: ComponentStateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: ComponentStateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    defer store.deinit();

    var counters: [40]*u32 = undefined;
    for (&counters, 0..) |*counter, i| {
        const id = try std.fmt.allocPrint(std.testing.allocator, "screen/{d}", .{i});
        defer std.testing.allocator.free(id);
        const state = try store.getOrCreate(id, State, State.init);
        counter.* = state.counter;
    }
    _ = try store.getOrCreate("other/kept", State, State.init);

    store.clearNamespace("screen/");

    for (counters) |counter| {
        try std.testing.expectEqual(@as(u32, 1), counter.*);
    }
    try std.testing.expect(store.get("other/kept", State) != null);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "ComponentStateStore deinit calls remaining deinit hooks" {
    deinit_test_counter = 0;

    const State = struct {
        fn init(_: ComponentStateInitContext) !@This() {
            return .{};
        }

        fn deinit(_: *@This(), _: ComponentStateDeinitContext) void {
            deinit_test_counter += 1;
        }
    };

    var store = ComponentStateStore.init(std.testing.allocator);
    _ = try store.getOrCreate("state", State, State.init);

    store.deinit();

    try std.testing.expectEqual(@as(u32, 1), deinit_test_counter);
}

var deinit_test_counter: u32 = 0;

const std = @import("std");

pub const StateInitContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
};

pub const StateDeinitContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
};

const StoredState = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    deinit_fn: ?*const fn (*anyopaque, StateDeinitContext) void,
};

pub const StateStore = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap(StoredState),
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return initWithIo(allocator, null);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: ?std.Io) StateStore {
        return .{
            .backing_allocator = allocator,
            .arena = .init(allocator),
            .map = .init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *StateStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.deinitStored(entry.value_ptr.*);
        }
        self.map.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getOrCreate(
        self: *StateStore,
        id: []const u8,
        comptime T: type,
        init_fn: *const fn (StateInitContext) anyerror!T,
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

    pub fn get(self: *StateStore, id: []const u8, comptime T: type) ?*T {
        const stored = self.map.get(id) orelse return null;
        self.assertType(T, stored);
        return typedPtr(T, stored.ptr);
    }

    pub fn remove(self: *StateStore, id: []const u8) void {
        if (self.map.fetchRemove(id)) |kv| {
            self.deinitStored(kv.value);
        }
    }

    pub fn clearNamespace(self: *StateStore, prefix: []const u8) void {
        while (true) {
            var found: ?[]const u8 = null;
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                    found = entry.key_ptr.*;
                    break;
                }
            }

            if (found) |id| {
                self.remove(id);
            } else {
                break;
            }
        }
    }

    pub fn count(self: *const StateStore) usize {
        return self.map.count();
    }

    fn deinitStored(self: *StateStore, stored: StoredState) void {
        if (stored.deinit_fn) |deinit_fn| {
            deinit_fn(stored.ptr, .{
                .allocator = self.arena.allocator(),
                .io = self.io,
            });
        }
    }

    fn assertType(self: *StateStore, comptime T: type, stored: StoredState) void {
        _ = self;
        const expected = typeName(T);
        if (!std.mem.eql(u8, stored.type_name, expected)) {
            std.debug.panic(
                "StateStore type mismatch: requested {s}, stored {s}",
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

fn deinitFn(comptime T: type) ?*const fn (*anyopaque, StateDeinitContext) void {
    if (!@hasDecl(T, "deinit")) return null;

    return struct {
        fn call(ptr: *anyopaque, ctx: StateDeinitContext) void {
            const typed = typedPtr(T, ptr);
            typed.deinit(ctx);
        }
    }.call;
}

test "StateStore getOrCreate creates and reuses state" {
    const State = struct {
        value: u32,

        fn init(_: StateInitContext) !@This() {
            return .{ .value = 1 };
        }
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.getOrCreate("counter", State, State.init);
    try std.testing.expectEqual(@as(u32, 1), first.value);
    first.value = 42;

    const second = try store.getOrCreate("counter", State, State.init);
    try std.testing.expectEqual(@as(u32, 42), second.value);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "StateStore get returns null for missing id" {
    const State = struct { value: u32 };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expect(store.get("missing", State) == null);
}

test "StateStore remove calls deinit and removes entry" {
    const State = struct {
        counter: *u32,

        fn init(ctx: StateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: StateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const state = try store.getOrCreate("state", State, State.init);
    const counter = state.counter;

    store.remove("state");

    try std.testing.expectEqual(@as(u32, 1), counter.*);
    try std.testing.expect(store.get("state", State) == null);
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "StateStore clearNamespace removes matching entries" {
    const State = struct {
        counter: *u32,

        fn init(ctx: StateInitContext) !@This() {
            const counter = try ctx.allocator.create(u32);
            counter.* = 0;
            return .{ .counter = counter };
        }

        fn deinit(self: *@This(), _: StateDeinitContext) void {
            self.counter.* += 1;
        }
    };

    var store = StateStore.init(std.testing.allocator);
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

test "StateStore deinit calls remaining deinit hooks" {
    deinit_test_counter = 0;

    const State = struct {
        fn init(_: StateInitContext) !@This() {
            return .{};
        }

        fn deinit(_: *@This(), _: StateDeinitContext) void {
            deinit_test_counter += 1;
        }
    };

    var store = StateStore.init(std.testing.allocator);
    _ = try store.getOrCreate("state", State, State.init);

    store.deinit();

    try std.testing.expectEqual(@as(u32, 1), deinit_test_counter);
}

var deinit_test_counter: u32 = 0;

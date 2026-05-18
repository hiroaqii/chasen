const std = @import("std");
const vaxis = @import("vaxis");

/// Opaque terminal image handle returned by the Chasen runtime.
///
/// Applications may store this in their model, but should not infer libvaxis
/// state from the fields. `generation` lets the runtime reject stale handles
/// after unload/replacement.
pub const TerminalImageHandle = struct {
    id: u32,
    generation: u32,
};

/// Image scaling policy for terminal image placement.
pub const TerminalImageFit = enum {
    none,
    fill,
    fit,
    contain,
};

/// Terminal image placement options.
pub const TerminalImageOptions = struct {
    fit: TerminalImageFit = .none,
    z_index: ?i32 = null,
};

pub const DrawError = error{
    TerminalImageRegistryUnavailable,
    InvalidTerminalImageHandle,
};

/// Result reason delivered when a terminal image load effect fails.
///
/// The runtime keeps the first API intentionally small. Detailed backend
/// diagnostics can be added later without exposing libvaxis error sets through
/// app messages.
pub const LoadError = enum {
    unsupported,
    load_failed,
    registry_full,
};

pub const PathLoadError = error{
    Unsupported,
    LoadFailed,
};

/// Backend Vaxis type used by `PathLoaderFn`.
///
/// External terminal adapters should name this alias instead of importing their
/// own `vaxis` module, so the function signature matches Chasen's module
/// instance exactly.
pub const LoaderVaxis = vaxis.Vaxis;

/// Backend image type returned by `PathLoaderFn`.
pub const LoaderImage = vaxis.Image;

/// Adapter hook used by terminal runners to turn a local path into a terminal
/// image. Core keeps this opt-in so apps that do not use terminal images avoid
/// compiling image decode/transmit code.
pub const PathLoaderFn = *const fn (
    ?*anyopaque,
    *LoaderVaxis,
    *std.Io.Writer,
    std.mem.Allocator,
    []const u8,
) PathLoadError!LoaderImage;

/// Default path loader used when terminal image loading is not configured.
pub fn unsupportedPathLoader(
    _: ?*anyopaque,
    _: *LoaderVaxis,
    _: *std.Io.Writer,
    _: std.mem.Allocator,
    _: []const u8,
) PathLoadError!LoaderImage {
    return error.Unsupported;
}

pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_generation: u32 = 1,

    const Entry = struct {
        handle: TerminalImageHandle,
        image: vaxis.Image,
    };

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *Registry, allocator: std.mem.Allocator, image: vaxis.Image) !TerminalImageHandle {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;

        const handle = TerminalImageHandle{
            .id = image.id,
            .generation = generation,
        };
        try self.entries.append(allocator, .{
            .handle = handle,
            .image = image,
        });
        return handle;
    }

    pub fn unload(self: *Registry, vx: vaxis.Vaxis, tty: *std.Io.Writer, handle: TerminalImageHandle) bool {
        const index = self.findIndex(handle) orelse return false;
        const entry = self.entries.swapRemove(index);
        vx.freeImage(tty, entry.image.id);
        return true;
    }

    pub fn freeAll(self: *Registry, vx: vaxis.Vaxis, tty: *std.Io.Writer) void {
        for (self.entries.items) |entry| {
            vx.freeImage(tty, entry.image.id);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn draw(self: *Registry, window: vaxis.Window, handle: TerminalImageHandle, opts: TerminalImageOptions) DrawError!void {
        const image = self.findImage(handle) orelse return error.InvalidTerminalImageHandle;
        image.draw(window, toVaxisOptions(opts)) catch return error.InvalidTerminalImageHandle;
    }

    fn findImage(self: *Registry, handle: TerminalImageHandle) ?vaxis.Image {
        const index = self.findIndex(handle) orelse return null;
        return self.entries.items[index].image;
    }

    fn findIndex(self: *Registry, handle: TerminalImageHandle) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.handle.id == handle.id and entry.handle.generation == handle.generation) return index;
        }
        return null;
    }
};

fn toVaxisOptions(opts: TerminalImageOptions) vaxis.Image.DrawOptions {
    return .{
        .scale = switch (opts.fit) {
            .none => .none,
            .fill => .fill,
            .fit => .fit,
            .contain => .contain,
        },
        .z_index = opts.z_index,
    };
}

test "Registry returns generation-checked handles" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const handle = try registry.add(std.testing.allocator, .{ .id = 10, .width = 20, .height = 30 });

    try std.testing.expectEqual(@as(u32, 10), handle.id);
    try std.testing.expectEqual(@as(u32, 1), handle.generation);
    try std.testing.expect(registry.findImage(handle) != null);
    try std.testing.expect(registry.findImage(.{ .id = 10, .generation = 2 }) == null);
}

test "Registry generations advance for stale handle detection" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const first = try registry.add(std.testing.allocator, .{ .id = 10, .width = 1, .height = 1 });
    const second = try registry.add(std.testing.allocator, .{ .id = 11, .width = 1, .height = 1 });

    try std.testing.expectEqual(@as(u32, 1), first.generation);
    try std.testing.expectEqual(@as(u32, 2), second.generation);
}

test {
    std.testing.refAllDecls(@This());
}

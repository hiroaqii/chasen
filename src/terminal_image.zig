const std = @import("std");
const vaxis = @import("vaxis");
pub const types = @import("terminal_image_types.zig");

pub const TerminalImageHandle = types.TerminalImageHandle;
pub const TerminalImageRequestId = types.TerminalImageRequestId;
pub const TerminalImageFit = types.TerminalImageFit;
pub const TerminalImageHorizontalAlign = types.TerminalImageHorizontalAlign;
pub const TerminalImageVerticalAlign = types.TerminalImageVerticalAlign;
pub const TerminalImageOptions = types.TerminalImageOptions;
pub const DrawError = types.DrawError;
pub const LoadError = types.LoadError;
pub const PathLoadError = types.PathLoadError;

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
        const draw_window = imageDrawWindow(window, image, opts);
        image.draw(draw_window, toVaxisOptions(opts)) catch return error.InvalidTerminalImageHandle;
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

fn imageDrawWindow(window: vaxis.Window, image: vaxis.Image, opts: TerminalImageOptions) vaxis.Window {
    const size = imageCellSize(window, image, opts.fit) orelse return window;
    const col = horizontalOffset(window.width, size.cols, opts.horizontal_align);
    const row = verticalOffset(window.height, size.rows, opts.vertical_align);
    return window.child(.{
        .x_off = @intCast(col),
        .y_off = @intCast(row),
        .width = size.cols,
        .height = size.rows,
    });
}

const ImageCellSize = struct {
    cols: u16,
    rows: u16,
};

fn imageCellSize(window: vaxis.Window, image: vaxis.Image, fit: TerminalImageFit) ?ImageCellSize {
    if (window.width == 0 or window.height == 0) return null;

    const pix_per_col = cellPixelWidth(window) orelse return null;
    const pix_per_row = cellPixelHeight(window) orelse return null;

    return switch (fit) {
        .fill => .{ .cols = window.width, .rows = window.height },
        .none => .{
            .cols = @min(window.width, ceilDivU16(image.width, pix_per_col)),
            .rows = @min(window.height, ceilDivU16(image.height, pix_per_row)),
        },
        .fit => fitImageCellSize(window, image, pix_per_col, pix_per_row, true),
        .contain => fitImageCellSize(window, image, pix_per_col, pix_per_row, false),
    };
}

fn fitImageCellSize(window: vaxis.Window, image: vaxis.Image, pix_per_col: u16, pix_per_row: u16, upscale: bool) ImageCellSize {
    const natural_cols = ceilDivU16(image.width, pix_per_col);
    const natural_rows = ceilDivU16(image.height, pix_per_row);
    if (!upscale and natural_cols <= window.width and natural_rows <= window.height) {
        return .{ .cols = natural_cols, .rows = natural_rows };
    }

    const by_width_rows = scaledRowsForCols(image, window.width, pix_per_col, pix_per_row);
    if (by_width_rows <= window.height) {
        return .{ .cols = window.width, .rows = @max(1, by_width_rows) };
    }

    const by_height_cols = scaledColsForRows(image, window.height, pix_per_col, pix_per_row);
    return .{ .cols = @max(1, @min(window.width, by_height_cols)), .rows = window.height };
}

fn scaledRowsForCols(image: vaxis.Image, cols: u16, pix_per_col: u16, pix_per_row: u16) u16 {
    const target_width_pix = @as(u64, cols) * pix_per_col;
    const rows = std.math.divCeil(u64, target_width_pix * image.height, @as(u64, image.width) * pix_per_row) catch return 1;
    return @intCast(@min(rows, std.math.maxInt(u16)));
}

fn scaledColsForRows(image: vaxis.Image, rows: u16, pix_per_col: u16, pix_per_row: u16) u16 {
    const target_height_pix = @as(u64, rows) * pix_per_row;
    const cols = std.math.divCeil(u64, target_height_pix * image.width, @as(u64, image.height) * pix_per_col) catch return 1;
    return @intCast(@min(cols, std.math.maxInt(u16)));
}

fn cellPixelWidth(window: vaxis.Window) ?u16 {
    if (window.screen.width == 0) return null;
    const value = std.math.divCeil(usize, window.screen.width_pix, window.screen.width) catch return null;
    if (value == 0) return null;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

fn cellPixelHeight(window: vaxis.Window) ?u16 {
    if (window.screen.height == 0) return null;
    const value = std.math.divCeil(usize, window.screen.height_pix, window.screen.height) catch return null;
    if (value == 0) return null;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

fn ceilDivU16(numerator: u16, denominator: u16) u16 {
    return std.math.divCeil(u16, numerator, denominator) catch 1;
}

fn horizontalOffset(available: u16, used: u16, alignment: TerminalImageHorizontalAlign) u16 {
    if (used >= available) return 0;
    const remaining = available - used;
    return switch (alignment) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
}

fn verticalOffset(available: u16, used: u16, alignment: TerminalImageVerticalAlign) u16 {
    if (used >= available) return 0;
    const remaining = available - used;
    return switch (alignment) {
        .top => 0,
        .middle => remaining / 2,
        .bottom => remaining,
    };
}

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

test "terminal image alignment offsets center within available cells" {
    try std.testing.expectEqual(@as(u16, 0), horizontalOffset(10, 10, .center));
    try std.testing.expectEqual(@as(u16, 3), horizontalOffset(10, 4, .center));
    try std.testing.expectEqual(@as(u16, 6), horizontalOffset(10, 4, .right));
    try std.testing.expectEqual(@as(u16, 2), verticalOffset(9, 4, .middle));
    try std.testing.expectEqual(@as(u16, 5), verticalOffset(9, 4, .bottom));
}

test {
    std.testing.refAllDecls(@This());
}

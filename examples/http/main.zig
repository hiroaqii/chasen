const std = @import("std");
const chasen = @import("chasen");

/// Max bytes to keep for display.
///
/// Msg values are copied through the event loop, so this demo keeps response
/// payloads small and bounded instead of sending an allocator-owned slice across
/// async boundaries. It also prevents a large HTTP response from overwhelming
/// the TUI.
const max_display = 512;

/// Bounded string that can be embedded in Msg and copied by value through the
/// event loop.
///
/// The async task cannot return a slice into its stack buffer, and returning an
/// allocator-owned slice would require an ownership protocol in the app. Keeping
/// a small fixed-size buffer makes the demo explicit and leak-free.
const BoundedStr = struct {
    buf: [max_display]u8 = .{0} ** max_display,
    len: usize = 0,

    fn slice(self: *const BoundedStr) []const u8 {
        return self.buf[0..self.len];
    }

    fn append(self: *BoundedStr, src: []const u8) void {
        const available = max_display - self.len;
        const n = @min(src.len, available);
        @memcpy(self.buf[self.len..][0..n], src[0..n]);
        self.len += n;
    }

    fn appendFmt(self: *BoundedStr, comptime fmt: []const u8, args: anytype) void {
        if (self.len >= max_display) return;
        var writer: std.Io.Writer = .fixed(self.buf[self.len..]);
        writer.print(fmt, args) catch {
            self.len = max_display;
            return;
        };
        self.len += writer.end;
    }

    fn from(src: []const u8) BoundedStr {
        var result: BoundedStr = .{};
        result.append(src);
        return result;
    }

    /// Extract readable text from a small HTML response for display.
    ///
    /// This is intentionally a tiny demo formatter, not a real HTML parser. It
    /// skips tags, skips non-body sections such as '<head>' and '<script>',
    /// collapses whitespace, and stops once the bounded Msg payload is full.
    fn fromHtmlText(src: []const u8) BoundedStr {
        var result: BoundedStr = .{};
        var i: usize = 0;
        var in_tag = false;
        var pending_space = false;

        while (i < src.len) {
            if (startsWithIgnoreCase(src[i..], "<head")) {
                i = skipUntilAfterIgnoreCase(src, i, "</head>");
                pending_space = true;
                continue;
            }
            if (startsWithIgnoreCase(src[i..], "<script")) {
                i = skipUntilAfterIgnoreCase(src, i, "</script>");
                pending_space = true;
                continue;
            }

            const c = src[i];
            i += 1;

            if (c == '<') {
                in_tag = true;
                pending_space = true;
                continue;
            }
            if (c == '>') {
                in_tag = false;
                pending_space = true;
                continue;
            }
            if (in_tag) continue;

            if (std.ascii.isWhitespace(c)) {
                pending_space = true;
                continue;
            }

            if (pending_space and result.len > 0) {
                if (result.len >= max_display) break;
                result.buf[result.len] = ' ';
                result.len += 1;
            }

            if (result.len >= max_display) break;
            result.buf[result.len] = c;
            result.len += 1;
            pending_space = false;
        }

        return result;
    }

    fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
    }

    fn skipUntilAfterIgnoreCase(src: []const u8, start: usize, closing_tag: []const u8) usize {
        var i = start;
        while (i + closing_tag.len <= src.len) : (i += 1) {
            if (startsWithIgnoreCase(src[i..], closing_tag)) {
                return i + closing_tag.len;
            }
        }
        return src.len;
    }
};

const HttpDemo = struct {
    state: State = .idle,

    const State = union(enum) {
        idle,
        loading,
        loaded: BoundedStr,
        failed: BoundedStr,
    };

    pub const Msg = union(enum) {
        fetch,
        got_response: BoundedStr,
        got_error: BoundedStr,
        quit,
    };

    pub fn handleEvent(self: *const HttpDemo, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                ' ' => .fetch,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *HttpDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .fetch => switch (self.state) {
                .loading => {},
                else => {
                    self.state = .loading;
                    try ctx.task().spawn(.{ .run = doFetch, .failed = fetchFailed });
                },
            },
            .got_response => |body| {
                self.state = .{ .loaded = body };
            },
            .got_error => |err_msg| {
                self.state = .{ .failed = err_msg };
            },
            .quit => ctx.quit(),
        }
    }

    /// Fetch http://example.com and return request/response details plus body.
    ///
    /// This uses the lower-level request API instead of `Client.fetch()` so the
    /// demo can show response metadata before reading the body.
    ///
    /// The 4096-byte buffer is sufficient for example.com (~1.2 KB response).
    /// Larger responses would overflow the fixed writer and result in
    /// WriteFailed, which is caught below and reported as got_error.
    /// For larger responses, prefer streaming only the displayable portion or
    /// using an allocator-backed writer with an explicit size limit.
    fn doFetch(allocator: std.mem.Allocator, io: std.Io) Msg {
        const url = "http://example.com";
        const method: std.http.Method = .GET;
        // Only explicitly configured request headers are shown in the UI. The
        // client may still add protocol-required headers such as Host.
        const request_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "text/html" },
        };

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = io,
        };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch {
            return .{ .got_error = BoundedStr.from("Invalid URL") };
        };

        var req = client.request(method, uri, .{
            .headers = .{
                .user_agent = .{ .override = "chasen-http-demo" },
                // Keep the demo body simple by asking std.http not to negotiate
                // compression. Production code can use readerDecompressing().
                .accept_encoding = .omit,
            },
            .extra_headers = &request_headers,
        }) catch {
            return .{ .got_error = BoundedStr.from("HTTP request failed") };
        };
        defer req.deinit();

        req.sendBodiless() catch {
            return .{ .got_error = BoundedStr.from("HTTP request failed") };
        };

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch {
            return .{ .got_error = BoundedStr.from("HTTP request failed") };
        };

        // Response header strings are borrowed from the response head buffer.
        // `response.reader()` invalidates those slices, so copy the displayable
        // header fields into BoundedStr before reading the body.
        var display: BoundedStr = .{};
        display.appendFmt("Request:\n{s} {s}\nuser-agent: chasen-http-demo\naccept: text/html\n\n", .{ @tagName(method), url });
        display.appendFmt("Response:\n{d} {s}\n", .{
            @intFromEnum(response.head.status),
            response.head.status.phrase() orelse response.head.reason,
        });
        if (response.head.content_type) |content_type| {
            display.appendFmt("content-type: {s}\n", .{content_type});
        }
        if (response.head.content_length) |content_length| {
            display.appendFmt("content-length: {d}\n", .{content_length});
        }
        display.append("\nBody:\n");

        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var transfer_buf: [64]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        _ = reader.streamRemaining(&writer) catch {
            return .{ .got_error = BoundedStr.from("HTTP request failed") };
        };

        const body = BoundedStr.fromHtmlText(buf[0..writer.end]);
        display.append(body.slice());

        return .{ .got_response = display };
    }

    pub fn view(self: *const HttpDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("HTTP Demo", .{ .bold = true });

        switch (self.state) {
            .idle => {
                col.borrowText("Press space to fetch http://example.com", .{ .fg = .gray });
            },
            .loading => {
                col.borrowText("Loading...", .{ .fg = .{ .index = 3 } });
            },
            .loaded => |body| {
                col.borrowText("Response:", .{ .fg = .{ .index = 2 } });
                col.borrowText(body.slice(), .{});
            },
            .failed => |err_msg| {
                col.borrowText("Error:", .{ .fg = .{ .index = 1 } });
                col.borrowText(err_msg.slice(), .{});
            },
        }

        col.borrowText("space: fetch  q: quit", .{ .dim = true });
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, HttpDemo{});
}

fn fetchFailed(failure: chasen.TaskFailure) HttpDemo.Msg {
    return .{ .got_error = switch (failure) {
        .start_failed => |message| BoundedStr.from(message),
    } };
}

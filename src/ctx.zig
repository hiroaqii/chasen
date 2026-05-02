const std = @import("std");

/// Context object passed to `update`, providing side-effect methods.
///
/// Currently only `quit()` is available. Methods like `spawn()`, `tick()`,
/// and `every()` will be added in the future.
pub fn Ctx(comptime Msg: type) type {
    _ = Msg;
    return struct {
        should_quit: bool = false,

        /// Request the application to exit.
        pub fn quit(self: *@This()) void {
            self.should_quit = true;
        }
    };
}

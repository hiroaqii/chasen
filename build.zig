const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("chasen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });

    const example_names = [_][]const u8{
        "counter",
        "stopwatch",
        "tick",
        "http",
        "animation",
        "runtime_stats",
        "surface_basics",
    };

    const check_examples_step = b.step("check-examples", "Build all examples");

    for (example_names) |name| {
        const example_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "chasen", .module = mod },
                },
            }),
        });

        const check_example_step = b.step(
            b.fmt("check-{s}", .{name}),
            b.fmt("Build the {s} example", .{name}),
        );
        check_example_step.dependOn(&example_exe.step);
        check_examples_step.dependOn(&example_exe.step);

        const run_example = b.addRunArtifact(example_exe);
        const run_example_step = b.step(
            b.fmt("run-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        );
        run_example_step.dependOn(&run_example.step);
    }

    const io_threaded_check = b.addExecutable(.{
        .name = "io-threaded-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/io_threaded/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_io_threaded_check = b.addRunArtifact(io_threaded_check);
    const io_threaded_check_step = b.step("check-io-threaded", "Run the std.Io.Threaded smoke test");
    io_threaded_check_step.dependOn(&run_io_threaded_check.step);

    const io_evented_check = b.addExecutable(.{
        .name = "io-evented-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/io_evented/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_io_evented_check = b.addRunArtifact(io_evented_check);
    const io_evented_check_step = b.step("try-io-evented", "Try the std.Io.Evented smoke test");
    io_evented_check_step.dependOn(&run_io_evented_check.step);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

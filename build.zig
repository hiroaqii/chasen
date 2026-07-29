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
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");
    const test_filters = if (test_filter) |filter|
        b.allocator.dupe([]const u8, &.{filter}) catch @panic("OOM")
    else
        &.{};
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

    const runtime_mod = b.addModule("chasen_runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
    });

    const example_names = [_][]const u8{
        "counter",
        "selection",
        "stopwatch",
        "tick",
        "http",
        "owned_task_result",
        "animation",
        "runtime_stats",
        "runtime_trace",
        "foreground_command",
        "surface_basics",
        "surface_layout",
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

    const chasen_anim_path = b.option([]const u8, "chasen-anim-path", "Path to a local chasen-anim checkout for the anim_transition example");
    const check_anim_transition_step = b.step("check-anim_transition", "Build the chasen-anim transition example");
    if (chasen_anim_path) |path| {
        const chasen_anim_mod = b.addModule("chasen_anim", .{
            .root_source_file = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ path, "src/root.zig" }) },
            .target = target,
            .optimize = optimize,
        });

        const anim_transition_exe = b.addExecutable(.{
            .name = "anim_transition",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/anim_transition/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "chasen", .module = mod },
                    .{ .name = "chasen_anim", .module = chasen_anim_mod },
                },
            }),
        });

        check_anim_transition_step.dependOn(&anim_transition_exe.step);
        check_examples_step.dependOn(&anim_transition_exe.step);

        const run_anim_transition = b.addRunArtifact(anim_transition_exe);
        const run_anim_transition_step = b.step("run-anim_transition", "Run the chasen-anim transition example");
        run_anim_transition_step.dependOn(&run_anim_transition.step);
    } else {
        const missing_chasen_anim = b.addFail("check-anim_transition requires -Dchasen-anim-path=/path/to/chasen-anim");
        check_anim_transition_step.dependOn(&missing_chasen_anim.step);
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
        .filters = test_filters,
    });
    const runtime_mod_tests = b.addTest(.{
        .root_module = runtime_mod,
        .filters = test_filters,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_runtime_mod_tests = b.addRunArtifact(runtime_mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_runtime_mod_tests.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const runtime_wasm = b.addObject(.{
        .name = "chasen-runtime-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_check.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chasen_runtime", .module = runtime_mod },
            },
        }),
    });
    const check_runtime_wasm_step = b.step("check-runtime-wasm", "Compile runtime-only Chasen API for wasm32-freestanding");
    check_runtime_wasm_step.dependOn(&runtime_wasm.step);

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

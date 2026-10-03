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
        .optimize = optimize,
        .link_libc = target.result.os.tag == .linux or target.result.os.tag == .macos,
        .target = target,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });

    const runtime_mod = b.addModule("chasen_runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .optimize = optimize,
        .target = target,
    });

    const example_names = [_][]const u8{
        "counter",
        "selection",
        "stopwatch",
        "tick",
        "http",
        "owned_task_result",
        "task_cancellation",
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
            .use_llvm = true,
            .use_lld = if (target.result.os.tag == .linux) true else null,
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

        if (std.mem.eql(u8, name, "foreground_command") or std.mem.eql(u8, name, "task_cancellation")) {
            const install_demo = b.addInstallArtifact(example_exe, .{});
            b.step(b.fmt("install-{s}", .{name}), b.fmt("Install the {s} demo for isolated manual QA", .{name})).dependOn(&install_demo.step);
        }
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
            .use_llvm = true,
            .use_lld = if (target.result.os.tag == .linux) true else null,
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
        .use_llvm = true,
        .use_lld = if (target.result.os.tag == .linux) true else null,
        .filters = test_filters,
    });
    const runtime_mod_tests = b.addTest(.{
        .root_module = runtime_mod,
        .filters = test_filters,
    });
    const task_consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/task_entry_consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chasen", .module = mod }},
        }),
        .use_llvm = true,
        .use_lld = if (target.result.os.tag == .linux) true else null,
        .filters = test_filters,
    });
    const check_task_tests = b.step("check-task-tests", "Compile task tests for native or cross targets");
    check_task_tests.dependOn(&mod_tests.step);
    check_task_tests.dependOn(&task_consumer_tests.step);
    b.step("check-foreground-tests", "Compile focused foreground tests for native or cross targets").dependOn(&mod_tests.step);

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_runtime_mod_tests = b.addRunArtifact(runtime_mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_runtime_mod_tests.step);
    test_step.dependOn(&b.addRunArtifact(task_consumer_tests).step);

    const timer_consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/timer_notice_consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chasen", .module = mod }},
        }),
        .use_llvm = true,
        .use_lld = if (target.result.os.tag == .linux) true else null,
        .filters = test_filters,
    });
    const timer_contract_step = b.step("test-timer-notice-contract", "Test timer notice values and reject implicit ownership");
    timer_contract_step.dependOn(&b.addRunArtifact(timer_consumer_tests).step);
    test_step.dependOn(timer_contract_step);

    // Only an internal test import: applications use Borrowed and the timer
    // request boundary, not a separate public validator API.
    const timer_contract = b.createModule(.{
        .root_source_file = b.path("src/timer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const timer_contract_tests = b.addTest(.{ .root_module = timer_contract, .filters = test_filters });
    timer_contract_step.dependOn(&b.addRunArtifact(timer_contract_tests).step);
    const negative_notices = [_]struct { name: []const u8, diagnostic: []const u8 }{
        .{ .name = "pointer", .diagnostic = "TimerNotice references require explicit Borrowed" },
        .{ .name = "slice", .diagnostic = "TimerNotice references require explicit Borrowed" },
        .{ .name = "nested-reference", .diagnostic = "TimerNotice references require explicit Borrowed" },
        .{ .name = "fake-borrowed", .diagnostic = "TimerNotice references require explicit Borrowed" },
        .{ .name = "fake-marker-value", .diagnostic = "TimerNotice references require explicit Borrowed" },
        .{ .name = "root-alias", .diagnostic = "Msg.TimerNotice must be separate from the root Msg type" },
        .{ .name = "untagged-union", .diagnostic = "TimerNotice must use tagged unions" },
        .{ .name = "function", .diagnostic = "TimerNotice supports only values and explicit Borrowed references" },
        .{ .name = "error-union", .diagnostic = "TimerNotice supports only values and explicit Borrowed references" },
        .{ .name = "not-a-type", .diagnostic = "Msg.TimerNotice must be a type" },
        .{ .name = "borrowed-nonpointer", .diagnostic = "Borrowed requires a pointer or slice type" },
    };
    for (negative_notices) |fixture| {
        const negative = b.addObject(.{
            .name = b.fmt("timer-{s}", .{fixture.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/compile_errors/timer-{s}.zig", .{fixture.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "timer_contract", .module = timer_contract },
                    .{ .name = "chasen", .module = mod },
                },
            }),
        });
        negative.expect_errors = .{ .contains = fixture.diagnostic };
        timer_contract_step.dependOn(&negative.step);
    }

    const osc52_step = b.step("test-osc52-ownership", "Check OSC 52 ownership without opening a terminal");
    const check_osc52_step = b.step("check-osc52-ownership", "Compile the OSC 52 ownership check for native or cross targets");
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        // A normal executable uses libvaxis's production Tty. Its macOS
        // TestTty is missing a method referenced by handleEventGeneric.
        const osc52_check = b.addExecutable(.{
            .name = "osc52-ownership",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/osc52_ownership.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                    .{ .name = "chasen_program_types", .module = b.createModule(.{
                        .root_source_file = b.path("src/program_types.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
                    }) },
                },
            }),
            .use_llvm = true,
            .use_lld = if (target.result.os.tag == .linux) true else null,
        });
        const run_osc52_check = b.addRunArtifact(osc52_check);
        osc52_step.dependOn(&run_osc52_check.step);
        check_osc52_step.dependOn(&osc52_check.step);
        // Preserve filtering by the name of the unit test moved to this fixture.
        const osc52_test_name = "libvaxis frees OSC 52 responses without queueing owned paste";
        if (test_filter == null or std.mem.indexOf(u8, osc52_test_name, test_filter.?) != null) {
            test_step.dependOn(&run_osc52_check.step);
        }
    } else {
        const unsupported = b.addFail("OSC 52 ownership check requires Linux or macOS");
        osc52_step.dependOn(&unsupported.step);
        check_osc52_step.dependOn(&unsupported.step);
    }

    const terminal_input_step = b.step(
        "test-terminal-input",
        "Run the Linux PTY terminal-input integration test",
    );
    if (target.result.os.tag == .linux) {
        const terminal_input_integration = b.addExecutable(.{
            .name = "terminal-input-integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/terminal_input_integration.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                },
            }),
            .use_llvm = true,
            .use_lld = if (target.result.os.tag == .linux) true else null,
        });
        const run_terminal_input_integration = b.addRunArtifact(terminal_input_integration);
        terminal_input_step.dependOn(&run_terminal_input_integration.step);
        if (test_filter == null) {
            test_step.dependOn(&run_terminal_input_integration.step);
        }
    } else {
        const unsupported = b.addFail("test-terminal-input requires a Linux target with PTY support");
        terminal_input_step.dependOn(&unsupported.step);
    }

    const foreground_step = b.step("test-foreground-command", "Run actual foreground runtime in isolated Linux PTYs");
    if (target.result.os.tag == .linux) {
        const foreground_test = b.addExecutable(.{
            .name = "foreground-command-integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/foreground_command_integration.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "chasen", .module = mod }},
            }),
            .use_llvm = true,
            .use_lld = if (target.result.os.tag == .linux) true else null,
        });
        const install_fixture = b.addInstallArtifact(foreground_test, .{});
        b.step("install-foreground-fixture", "Install the isolated foreground PTY helper").dependOn(&install_fixture.step);
        const run_foreground_test = b.addRunArtifact(foreground_test);
        foreground_step.dependOn(&run_foreground_test.step);
        if (test_filter == null) test_step.dependOn(&run_foreground_test.step);
    } else foreground_step.dependOn(&b.addFail("foreground PTY gate requires Linux").step);

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

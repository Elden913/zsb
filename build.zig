const std = @import("std");
const Scanner = @import("wayland").Scanner;

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
    //
    const optimize = b.standardOptimizeOption(.{});
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(.{ .cwd_relative = "/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml" });
    scanner.addCustomProtocol(.{ .cwd_relative = "dwl-ipc-unstable-v2-client.xml" });
    scanner.addSystemProtocol("staging/ext-workspace/ext-workspace-v1.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 1);
    scanner.generate("zwlr_layer_shell_v1", 1);
    scanner.generate("ext_workspace_manager_v1", 1);
    scanner.generate("zdwl_ipc_manager_v2", 2);

    const pixman = b.dependency("pixman", .{
    });

    const fcft = b.dependency("fcft", .{
    });

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.
    // If neither case applies to you, feel free to delete the declaration you
    const exe = b.addExecutable(.{
        .name = "dsb",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{},
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.addImport("pixman", pixman.module("pixman"));
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    exe.root_module.linkSystemLibrary("pulse", .{});
    fcft.module("fcft").addImport("pixman", pixman.module("pixman"));
    exe.root_module.addImport("fcft", fcft.module("fcft"));
    exe.root_module.linkSystemLibrary("fcft", .{});

    // exe.root_module.linkSystemLibrary("fcft", .{});

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

const std = @import("std");
//const pkgs = @import("gyro").pkgs;

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    {
        const server_exe = b.addExecutable("async_io_uring_server", "src/server.zig");
        server_exe.setTarget(target);
        server_exe.setBuildMode(mode); //pkgs.addAllTo(server_exe);
        server_exe.install();

        const run_cmd = server_exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run_server", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const client_exe = b.addExecutable("async_io_uring_client", "src/client.zig");
        client_exe.setTarget(target);
        client_exe.setBuildMode(mode);
        //pkgs.addAllTo(client_exe);
        client_exe.install();

        const run_cmd = client_exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run_client", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const exe = b.addExecutable("async_io_uring_benchmark", "src/benchmark.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        //pkgs.addAllTo(exe);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run_benchmark", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}

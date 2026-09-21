const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk = sdk_build.sdk(b, b.dependencyFromBuildZig(sdk_build, .{}), .{});
    const artifact = sdk.addR4MF(b.path("module.R4MF"));
    const verify = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    verify.addFileArg(b.path("Tools/VerifyIdentity.ps1"));
    verify.has_side_effects = true;
    artifact.code.generated.file.step.dependOn(&verify.step);
    const native = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    native.addFileArg(b.path("Tools/BuildPort.ps1"));
    native.has_side_effects = true;
    artifact.output.generated.file.step.dependOn(&native.step);
    const host = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    host.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    host.addIncludePath(b.path("ThirdParty/Linux7.2.4/Original/drivers/gpu/drm/amd/include"));
    const tests = b.addTest(.{ .root_module = host });
    tests.step.dependOn(&verify.step);
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Check AMD probe ownership and original freestanding DCN1 dependency");
    test_step.dependOn(&native.step);
    test_step.dependOn(&run.step);
    artifact.output.generated.file.step.dependOn(&run.step);
}

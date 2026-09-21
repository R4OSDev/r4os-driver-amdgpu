const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk = sdk_build.sdk(b, b.dependencyFromBuildZig(sdk_build, .{}), .{});
    const artifact = sdk.addR4MF(b.path("module.R4MF"));
    const native = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    native.addFileArg(b.path("Tools/BuildPort.ps1"));
    native.has_side_effects = true;
    artifact.output.generated.file.step.dependOn(&native.step);
    b.step("test", "Compile original DCN1 dependencies for the freestanding target").dependOn(&native.step);
}

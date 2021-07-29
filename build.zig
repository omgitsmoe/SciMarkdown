const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("scimd", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    // exe.addPackage(.{
    //     .name = "zig-clap",
    //     .path = "deps/zig-clap/clap.zig",
    // });
    exe.addPackagePath("zig-clap", "deps/zig-clap/clap.zig");

    // wrtie hpdf_config.h for libharu
    const libharu_config = try std.fs.cwd().createFile(
        "vendor/libharu/include/hpdf_config.h",
        // truncate: reduce file to length 0 if it exists
        .{ .read = true, .truncate = true },
    );
    try libharu_config.writeAll(
        \\/* include/hpdf_config.h.in.  Generated from configure.in by autoheader.  */
        \\
        \\/* Define to 1 if you have the <dlfcn.h> header file. */
        \\/* #undef LIBHPDF_HAVE_DLFCN_H */
        \\
        \\/* Define to 1 if you have the <inttypes.h> header file. */
        \\#define LIBHPDF_HAVE_INTTYPES_H
        \\
        \\/* Define to 1 if you have the `png' library (-lpng). */
        \\/* #undef LIBHPDF_HAVE_LIBPNG */
        \\
        \\/* Define to 1 if you have the `z' library (-lz). */
        \\/* #undef LIBHPDF_HAVE_LIBZ */
        \\
        \\/* Define to 1 if you have the <memory.h> header file. */
        \\#define LIBHPDF_HAVE_MEMORY_H
        \\
        \\/* Define to 1 if you have the <stdint.h> header file. */
        \\#define LIBHPDF_HAVE_STDINT_H
        \\
        \\/* Define to 1 if you have the <stdlib.h> header file. */
        \\#define LIBHPDF_HAVE_STDLIB_H
        \\
        \\/* Define to 1 if you have the <strings.h> header file. */
        \\/* #undef LIBHPDF_HAVE_STRINGS_H */
        \\
        \\/* Define to 1 if you have the <string.h> header file. */
        \\#define LIBHPDF_HAVE_STRING_H
        \\
        \\/* Define to 1 if you have the <sys/stat.h> header file. */
        \\#define LIBHPDF_HAVE_SYS_STAT_H
        \\
        \\/* Define to 1 if you have the <sys/types.h> header file. */
        \\#define LIBHPDF_HAVE_SYS_TYPES_H
        \\
        \\/* Define to 1 if you have the <unistd.h> header file. */
        \\/* #undef LIBHPDF_HAVE_UNISTD_H */
        \\
        \\/* debug build */
        \\/* #undef LIBHPDF_DEBUG */
        \\
        \\/* debug trace enabled */
        \\/* #undef LIBHPDF_DEBUG_TRACE */
        \\
        \\/* libpng is not available */
        \\#define LIBHPDF_HAVE_NOPNGLIB
        \\#define HPDF_NOPNGLIB
        \\
        \\/* zlib is not available */
        \\#define LIBHPDF_HAVE_NOZLIB
        \\
        \\/* Define to the address where bug reports for this package should be sent. */
        \\#define LIBHPDF_PACKAGE_BUGREPORT "TODO"
        \\
        \\/* Define to the full name of this package. */
        \\#define LIBHPDF_PACKAGE_NAME "libHaru-2.2.0-vc"
        \\
        \\/* Define to the full name and version of this package. */
        \\#define LIBHPDF_PACKAGE_STRING "libHaru-2.2.0-vc"
        \\
        \\/* Define to the one symbol short name of this package. */
        \\#define LIBHPDF_PACKAGE_TARNAME "TODO"
        \\
        \\/* Define to the version of this package. */
        \\#define LIBHPDF_PACKAGE_VERSION "2.2.0"
        \\
        \\/* Define to 1 if you have the ANSI C header files. */
        \\#define LIBHPDF_STDC_HEADERS
        \\
        \\/* Define to `unsigned int' if <sys/types.h> does not define. */
        \\/* #undef LIBHPDF_size_t */
    );
    libharu_config.close();

    const libharu = b.addStaticLibrary("libharu", null);
    libharu.addIncludeDir("vendor/libharu/include");
    libharu.linkSystemLibrary("c");

    // add libharu src files to libharu
    var buf: [1000]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&buf);
    const libharu_src_dir = try std.fs.cwd().openDir("vendor/libharu/src", .{ .iterate = true });
    var libharu_src_dir_iter = libharu_src_dir.iterate();
    while (try libharu_src_dir_iter.next()) |entry| {
        switch (entry.kind) {
            .File => {
                if (!std.mem.endsWith(u8, entry.name, ".c"))
                    continue;

                const path = try std.mem.concat(
                    &alloc.allocator, u8,
                    &[_][]const u8 { "vendor/libharu/src/", entry.name });

                // std.debug.print("Adding {s}\n", .{path});
                libharu.addCSourceFile(path, &[_][]const u8{ "-ansi" });
                alloc.reset();
            },
            else => continue,
        }
    }

    exe.linkLibrary(libharu);
    // we can either let the zig compiler handle building the library, which has the
    // only downside that we need to generate the hpdf_config.h, which differs from
    // system to system
    // __or__ we can build it separately and then add it as lib/obj file
    // this still fails complaining that libMSVCRT.a and libOLDNAMES.a is missing
    // __fixed__ by running it in a cmd env with vcvarsall.bat (x86|x64|..)
    // exe.addObjectFile("vendor/libharu/build/libharu.lib/Release/libhpdfs.lib");
    // this doesn't work at all (says symbol HPDF_New not found even though the .lib clearly exports it
    // (checked with dumpbin)):
    // exe.addLibPath("vendor/libharu/build/libharu.lib/Release/libhpdfs.lib");
    exe.addIncludeDir("vendor/libharu/include");
    exe.linkSystemLibrary("c");

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

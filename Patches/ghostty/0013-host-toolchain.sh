#!/bin/bash
# Host-toolchain robustness for the static-library build. Neither edit is
# target-specific; both were found building on Xcode 27 and hold everywhere.
#
# 1. LibtoolStep combines the static archives with `zig ar` (llvm-ar) in
#    Darwin format instead of Xcode's libtool. Zig writes its archive members
#    2-byte aligned, and the libtool in Xcode 27 (cctools 27037) drops every
#    misaligned 64-bit member *silently* — oniguruma, libintl, freetype, simd
#    vanish from libghostty-fat.a and only the consuming app's link notices.
# 2. libghostty-vt.dylib is not installed. The XCFramework ships libghostty.a
#    only; the dylib's libc++ sub-compilation is what fails under Xcode 27
#    (`INFINITY` undeclared in clamp_to_integral.h), and on visionOS it fails
#    under every Xcode. Nothing downstream reads it.
set -euo pipefail
SOURCE_DIR=${1:?usage: $0 <ghostty_source_dir>}
cd "$SOURCE_DIR"

if grep -q 'LIBGHOSTTY_SPM_ZIG_AR_PATCH' src/build/LibtoolStep.zig; then
    echo "[+] LibtoolStep already uses zig ar"
else
    perl -0pi -e 's/    run_step\.addArgs\(&\.\{ "libtool", "-static", "-o" \}\);\n/    \/\/ LIBGHOSTTY_SPM_ZIG_AR_PATCH: Zig writes its archives 2-byte aligned and\n    \/\/ Xcode 27 libtool (cctools 27037) drops every misaligned 64-bit member\n    \/\/ silently, so combine with llvm-ar in Darwin format instead.\n    run_step.addArgs(&.{ b.graph.zig_exe, "ar", "qcsL", "--format=darwin" });\n/' src/build/LibtoolStep.zig
    grep -q 'LIBGHOSTTY_SPM_ZIG_AR_PATCH' src/build/LibtoolStep.zig || { echo "[!] LibtoolStep.zig patch failed"; exit 1; }
    echo "[+] patched LibtoolStep.zig: zig ar"
fi

if grep -q 'LIBGHOSTTY_SPM_NO_VT_DYLIB' build.zig; then
    echo "[+] libghostty-vt.dylib install already skipped"
else
    perl -0pi -e 's/^    libghostty_vt_shared\.install\(b\.getInstallStep\(\)\);\n/    \/\/ LIBGHOSTTY_SPM_NO_VT_DYLIB: the XCFramework ships libghostty.a only.\n/m' build.zig
    grep -q 'LIBGHOSTTY_SPM_NO_VT_DYLIB' build.zig && ! grep -q 'libghostty_vt_shared.install(b.getInstallStep())' build.zig || { echo "[!] build.zig vt install patch failed"; exit 1; }
    echo "[+] patched build.zig: libghostty-vt.dylib not installed"
fi
echo "[+] all host-toolchain patches applied"

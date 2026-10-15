#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Link GNU libintl only when i18n is on
# =============================================================================
#
# libintl is LGPL-2.1-or-later. Upstream links its bundled copy into every
# Darwin build, whatever `-Di18n` says, and appends it to the static
# libraries that make up libghostty.a, so the archive every host app links
# carried it (issue #88). Static LGPL code puts a relinking obligation on
# every app that ships the package.
#
# Script/build-ghostty.sh passes `-Di18n=false`, which turns every gettext
# call off at comptime (src/os/i18n.zig). The package ships no message
# catalogs, so those calls only ever returned their msgid. This edit makes
# the link follow the option, so the dependency is neither fetched nor
# linked.
#
# The one thing libintl did that reached a user was converting Apple's
# preferred languages for LANGUAGE (os/locale.zig, setLangFromCocoa).
# GhosttyTerminal's TerminalLocaleEnvironment now sets LANG and LANGUAGE
# before ghostty_init, so that code finds LANG set and never runs.
#
# Script/verify-xcframework.sh refuses an archive that defines a libintl
# symbol; source-build.yml checks every slice the same way.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

src = Source(source_dir, "src/build/SharedDeps.zig")
src.replace(
    """        // Apple platforms do not include libc libintl so we bundle it.
        // This is LGPL but since our source code is open source we are
        // in compliance with the LGPL since end users can modify this
        // build script to replace the bundled libintl with their own.
        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.root_module.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
""",
    """        // libghostty-spm: libintl (LGPL) is linked only when i18n is on.
        // The package builds with -Di18n=false, so libghostty.a carries
        // none of it.
        if (self.config.i18n) {
            if (b.lazyDependency("libintl", .{
                .target = target,
                .optimize = optimize,
            })) |libintl_dep| {
                step.root_module.linkLibrary(libintl_dep.artifact("intl"));
                try static_libs.append(
                    b.allocator,
                    libintl_dep.artifact("intl").getEmittedBin(),
                );
            }
        }
""",
)
src.save()
PY

echo "[+] libintl linked only with i18n"

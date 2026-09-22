"""Exact-anchor source edits for the Ghostty patch stack.

A unified diff pins every hunk to line numbers and to three lines of whatever
code happens to sit around it, so an unrelated upstream edit next door breaks
the patch. An edit made here names only the code it depends on: the anchor
must occur in the file exactly once, byte for byte, or the run fails. There
is no fuzz, no reduced context and no nearest match. An anchor that moved is
still found; an anchor that changed, vanished or became ambiguous stops the
build, which is the point.

Every edit is idempotent: text that is already in place is reported and left
alone, so a patch can run again over a source tree it has already patched.
When a later patch in the stack rewrites part of what an edit added (the
platform patches widen every `.ios` check), the edit names a `marker`: one
line of its addition that the later patches leave alone, which is then what
proves the edit is in place.

    from anchored_edit import Source

    src = Source(source_dir, "src/terminal/Terminal.zig")
    src.insert_before("pub const Foo = enum {", NEW_DECL)
    src.replace(OLD_BODY, NEW_BODY)
    src.replace(OLD_CHECK, NEW_CHECK, marker="    if (drift > max_drift) return;\n")
    src.expect_count("mutex.unlock(", 3)   # tripwire: fail when upstream adds one
    src.save()
"""

import sys
from pathlib import Path


class AnchorError(SystemExit):
    def __init__(self, path, message):
        super().__init__(f"[-] {path}: {message}")


class Source:
    def __init__(self, source_dir, relative_path):
        self.relative_path = relative_path
        self.path = Path(source_dir) / relative_path
        if not self.path.is_file():
            raise AnchorError(relative_path, "file not found")
        self.text = self.path.read_text()
        self.changed = False

    def _only(self, anchor, what):
        count = self.text.count(anchor)
        if count != 1:
            first_line = anchor.strip().splitlines()[0]
            raise AnchorError(
                self.relative_path,
                f"{what} must occur exactly once, found {count}: {first_line!r}",
            )

    def _applied(self, new_text):
        count = self.text.count(new_text)
        if count > 1:
            first_line = new_text.strip().splitlines()[0]
            raise AnchorError(
                self.relative_path,
                f"patched text occurs {count} times: {first_line!r}",
            )
        return count == 1

    def expect_count(self, needle, count):
        """Fail unless `needle` occurs exactly `count` times.

        A tripwire for edits that must cover every occurrence of something:
        when upstream adds another, the patch has to be revisited by hand.
        """
        found = self.text.count(needle)
        if found != count:
            raise AnchorError(
                self.relative_path,
                f"expected {count} of {needle!r}, found {found}; "
                "upstream changed what this patch has to cover",
            )

    def replace(self, old, new, marker=None):
        if self._applied(marker or new) and old not in self.text.replace(new, ""):
            return
        self._only(old, "text to replace")
        self.text = self.text.replace(old, new)
        self.changed = True

    def insert_before(self, anchor, addition, marker=None):
        if self._applied(marker or addition):
            return
        self._only(anchor, "anchor")
        self.text = self.text.replace(anchor, addition + anchor)
        self.changed = True

    def insert_after(self, anchor, addition, marker=None):
        if self._applied(marker or addition):
            return
        self._only(anchor, "anchor")
        self.text = self.text.replace(anchor, anchor + addition)
        self.changed = True

    def append(self, addition, marker=None):
        if self._applied(marker or addition):
            return
        self.text = self.text + addition
        self.changed = True

    def save(self):
        if self.changed:
            self.path.write_text(self.text)
            print(f"[+] patched {self.relative_path}")
        else:
            print(f"[+] {self.relative_path} already patched")


if __name__ == "__main__":
    sys.exit("anchored_edit is a library for the scripts under Patches/ghostty")

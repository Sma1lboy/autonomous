#!/usr/bin/env bash
# test_dispatch_paths.sh — Verify dispatch.py emits POSIX paths into the
# generated bash wrapper.  Regression guard for Windows where `str(Path)`
# returns backslash-separated paths that bash collapses as escape sequences
# (`E:\Projects\foo` → `EProjectsfoo` → "No such file or directory").
#
# The wrapper is bash, so its content must always be POSIX-style regardless
# of the host OS.  These tests fail if any future change reintroduces
# `str(path)` in a place that crosses the bash boundary.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_dispatch_paths.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. render_wrapper_content uses POSIX paths from POSIX inputs ───────────
echo ""
echo "1. render_wrapper_content uses POSIX paths"

OUT=$(SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "dispatch", os.path.join(os.environ["SCRIPTS_DIR"], "dispatch.py")
)
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)

content = dispatch.render_wrapper_content(
    "/tmp/proj", "/tmp/proj/.autonomous/prompt.md", None
)
# shlex.quote() omits quotes for paths without special chars, so we just
# verify the path appears in the right command verbatim.
assert "cd /tmp/proj\n" in content, content
assert "$(cat /tmp/proj/.autonomous/prompt.md)" in content, content
assert "\\" not in content, f"backslash leaked into bash wrapper: {content!r}"
print("OK")
PYEOF
)
assert_eq "$OUT" "OK" "POSIX inputs -> POSIX wrapper content (no backslashes)"

# ── 2. Windows-style PureWindowsPath converts to forward slashes ───────────
echo ""
echo "2. PureWindowsPath inputs convert to forward slashes via .as_posix()"

OUT=$(SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PYEOF'
import importlib.util, os, sys
from pathlib import PureWindowsPath
spec = importlib.util.spec_from_file_location(
    "dispatch", os.path.join(os.environ["SCRIPTS_DIR"], "dispatch.py")
)
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)

# Simulate what create_wrapper does on Windows: a Windows path's as_posix()
# yields forward slashes.  render_wrapper_content must accept that without
# reintroducing backslashes.
proj = PureWindowsPath(r"E:\Projects\harness-lab")
prompt = PureWindowsPath(r"E:\Projects\harness-lab\.autonomous\sprint-prompt.md")
content = dispatch.render_wrapper_content(
    proj.as_posix(), prompt.as_posix(), None
)
assert "E:/Projects/harness-lab" in content, content
assert "\\" not in content, f"backslash leaked: {content!r}"
print("OK")
PYEOF
)
assert_eq "$OUT" "OK" "Windows path .as_posix() flows through cleanly (no backslashes)"

# ── 3. Settings path also POSIX-ified ──────────────────────────────────────
echo ""
echo "3. settings_path is POSIX-quoted when present"

OUT=$(SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PYEOF'
import importlib.util, os
spec = importlib.util.spec_from_file_location(
    "dispatch", os.path.join(os.environ["SCRIPTS_DIR"], "dispatch.py")
)
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)

content = dispatch.render_wrapper_content(
    "/tmp/proj",
    "/tmp/proj/.autonomous/prompt.md",
    "/tmp/proj/.autonomous/settings-sprint-1.json",
)
assert "--settings /tmp/proj/.autonomous/settings-sprint-1.json " in content, content
assert "\\" not in content
print("OK")
PYEOF
)
assert_eq "$OUT" "OK" "settings_path injected with shlex.quote and forward slashes"

# ── 4. End-to-end: create_wrapper writes POSIX-only content to disk ────────
echo ""
echo "4. create_wrapper writes wrapper with no backslashes"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"

OUT=$(SCRIPTS_DIR="$SCRIPTS_DIR" PROJ="$T" python3 - <<'PYEOF'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location(
    "dispatch", os.path.join(os.environ["SCRIPTS_DIR"], "dispatch.py")
)
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)

proj = Path(os.environ["PROJ"]).resolve()
prompt = proj / ".autonomous" / "prompt.md"
wrapper = dispatch.create_wrapper(proj, prompt, "sprint-1")
content = wrapper.read_text()
assert "\\" not in content, f"backslash in wrapper: {content!r}"
assert content.startswith("#!/bin/bash"), content
print("OK")
PYEOF
)
assert_eq "$OUT" "OK" "create_wrapper writes wrapper containing no backslashes"

# ── 5. Source-level guard: no `str(...)` of a Path on bash-bound spots ─────
echo ""
echo "5. Source guard: bash-bound paths use .as_posix(), not str()"

# These five lines were the original Windows-incompat sites.  If they
# regress to str(path), grep finds them.
DISPATCH="$SCRIPTS_DIR/dispatch.py"
assert_file_not_contains "$DISPATCH" 'shlex.quote(str(project_dir))' \
  "no shlex.quote(str(project_dir)) — must be .as_posix()"
assert_file_not_contains "$DISPATCH" 'shlex.quote(str(prompt_file))' \
  "no shlex.quote(str(prompt_file)) — must be .as_posix()"
assert_file_not_contains "$DISPATCH" '"bash", str(wrapper)' \
  "no [\"bash\", str(wrapper)] — must use wrapper.as_posix()"
assert_file_contains "$DISPATCH" 'project_dir.as_posix()' \
  "create_wrapper uses project_dir.as_posix()"
assert_file_contains "$DISPATCH" 'prompt_file.as_posix()' \
  "create_wrapper uses prompt_file.as_posix()"

print_results

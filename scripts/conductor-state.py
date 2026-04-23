#!/usr/bin/env python3
"""State management for the multi-sprint conductor."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from textwrap import dedent
from typing import Any, NoReturn

# Allow sibling import of timeline.py for event emission.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import timeline as _timeline  # type: ignore[import-not-found]
except Exception:  # pragma: no cover — timeline is optional; never break conductor
    _timeline = None


def _emit(project: Path, event: str, **fields: Any) -> None:
    """Emit a timeline event, swallowing any error."""
    if _timeline is None:
        return
    try:
        _timeline.emit(project, event, **fields)
    except Exception:
        pass


class StateManager:
    def __init__(self, project_dir: Path) -> None:
        self.project = project_dir
        self.state_dir = self.project / ".autonomous"
        self.state_file = self.state_dir / "conductor-state.json"
        self.lock_file = self.state_dir / "conductor.lock"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self._lock_acquired = False

    # ----- Locking -----------------------------------------------------
    def acquire_lock(self) -> None:
        if self._lock_acquired:
            return
        while True:
            try:
                fd = os.open(self.lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                with os.fdopen(fd, "w") as handle:
                    handle.write(str(os.getpid()))
                self._lock_acquired = True
                return
            except FileExistsError:
                try:
                    pid_text = self.lock_file.read_text().strip()
                    pid = int(pid_text)
                except Exception:
                    pid = None
                if pid:
                    if _pid_alive(pid):
                        _die(f"Another conductor is running (PID {pid}). Lock: {self.lock_file}")
                    else:
                        self.lock_file.unlink(missing_ok=True)
                        continue
                else:
                    self.lock_file.unlink(missing_ok=True)

    def release_lock(self) -> None:
        if self._lock_acquired:
            self.lock_file.unlink(missing_ok=True)
            self._lock_acquired = False

    # ----- State helpers -----------------------------------------------
    def read_state(self) -> dict[str, Any]:
        if not self.state_file.exists():
            return {}
        try:
            return json.loads(self.state_file.read_text())
        except (json.JSONDecodeError, OSError):
            return {}

    def read_state_strict(self) -> dict[str, Any]:
        state = self.read_state()
        if not state:
            _die("No conductor state found. Run 'init' first.")
        return state

    def write_state(self, data: dict[str, Any]) -> None:
        tmp = self.state_file.with_suffix(
            self.state_file.suffix + f".tmp.{os.getpid()}"
        )
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(self.state_file)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def usage() -> None:
    print(
        dedent(
            """\
            Usage: conductor-state.py <command> <project-dir> [args...]

            Commands:
              init <project> <mission> [max-sprints]
              read <project>
              sprint-start <project> <direction>
              sprint-end <project> <status> <summary> [commits-json] [direction-complete]
              phase <project>
              explore-pick <project>
              explore-score <project> <dimension> <score>
              set-phase <project> <phase>
              lock <project>
              unlock <project>

            Examples:
              python3 scripts/conductor-state.py init ./my-project "build REST API" 5
              python3 scripts/conductor-state.py sprint-start ./my-project "add auth middleware"
              python3 scripts/conductor-state.py explore-pick ./my-project
            """
        ).strip()
    )


def cmd_init(manager: StateManager, args: list[str]) -> None:
    if not args:
        _die("Usage: conductor-state.py init <project-dir> <mission> [max-sprints]")
    mission = args[0]
    max_sprints = args[1] if len(args) > 1 else "10"
    if not mission:
        _die("mission is required")
    try:
        ms_int = int(max_sprints)
    except ValueError:
        _die(f"max-sprints must be a positive integer, got: {max_sprints}")
    if ms_int <= 0:
        _die(f"max-sprints must be > 0, got: {max_sprints}")

    manager.state_dir.mkdir(parents=True, exist_ok=True)
    (manager.state_dir / "sprint-summary.json").unlink(missing_ok=True)
    for file in manager.state_dir.glob("sprint-*-summary.json"):
        file.unlink(missing_ok=True)

    manager.acquire_lock()

    session_id = f"conductor-{int(time.time())}"
    max_directed = max(1, int(ms_int * 0.7))
    state = {
        "session_id": session_id,
        "mission": mission,
        "phase": "directed",
        "max_sprints": ms_int,
        "max_directed_sprints": max_directed,
        "sprints": [],
        "consecutive_complete": 0,
        "consecutive_zero_commits": 0,
        "exploration": {
            "test_coverage": {"audited": False, "score": None},
            "error_handling": {"audited": False, "score": None},
            "security": {"audited": False, "score": None},
            "code_quality": {"audited": False, "score": None},
            "documentation": {"audited": False, "score": None},
            "architecture": {"audited": False, "score": None},
            "performance": {"audited": False, "score": None},
            "dx": {"audited": False, "score": None},
        },
    }
    manager.write_state(state)
    _emit(
        manager.project,
        "session-start",
        session_id=session_id,
        mission=mission,
        max_sprints=ms_int,
    )
    print(session_id)


def cmd_read(manager: StateManager) -> None:
    print(json.dumps(manager.read_state(), indent=2))


def cmd_sprint_start(manager: StateManager, args: list[str]) -> None:
    if not args:
        _die("Usage: conductor-state.py sprint-start <project-dir> <direction>")
    direction = args[0]
    state = manager.read_state_strict()
    sprints = state.setdefault("sprints", [])
    sprint_num = len(sprints) + 1
    sprints.append(
        {
            "number": sprint_num,
            "direction": direction,
            "status": "running",
            "commits": [],
            "summary": "",
        }
    )
    manager.write_state(state)
    _emit(
        manager.project,
        "sprint-start",
        sprint=sprint_num,
        direction=direction,
        phase=state.get("phase", "directed"),
    )
    print(sprint_num)


def cmd_sprint_end(manager: StateManager, args: list[str]) -> None:
    if len(args) < 2:
        _die(
            "Usage: conductor-state.py sprint-end <project-dir> <status> <summary> [commits-json] [direction-complete]"
        )
    status, summary = args[0], args[1]
    commits_json = args[2] if len(args) > 2 else "[]"
    direction_complete = args[3] if len(args) > 3 else "false"

    state = manager.read_state_strict()
    try:
        commits = json.loads(commits_json)
    except json.JSONDecodeError:
        commits = []
    direction_done = direction_complete.lower() == "true"
    prev_phase = state.get("phase", "directed")

    sprints = state.get("sprints", [])
    if not sprints:
        manager.write_state(state)
        print(state.get("phase", "directed"))
        return

    last = sprints[-1]
    last.update(
        {
            "status": status,
            "summary": summary,
            "commits": commits,
            "direction_complete": direction_done,
        }
    )

    if direction_done:
        state["consecutive_complete"] = state.get("consecutive_complete", 0) + 1
    else:
        state["consecutive_complete"] = 0

    if len(commits) == 0:
        state["consecutive_zero_commits"] = state.get("consecutive_zero_commits", 0) + 1
    else:
        state["consecutive_zero_commits"] = 0

    if state.get("phase") == "directed":
        # Under the roadmap architecture, phase transitions from 'directed'
        # to 'exploring' are managed manually by the Conductor using `set-phase`
        # when ROADMAP.md is depleted. Auto-transitions have been removed to
        # prevent prematurely aborting a multi-sprint roadmap.
        pass

    manager.write_state(state)
    new_phase = state.get("phase", "directed")

    sprint_num_emit = len(sprints)
    _emit(
        manager.project,
        "sprint-end",
        sprint=sprint_num_emit,
        status=status,
        commits=len(commits),
        direction_complete=direction_done,
        phase=new_phase,
    )
    if new_phase != prev_phase:
        _emit(
            manager.project,
            "phase-transition",
            sprint=sprint_num_emit,
            **{"from": prev_phase, "to": new_phase},
            reason=state.get("phase_transition_reason", ""),
        )

    print(new_phase)


def cmd_phase(manager: StateManager) -> None:
    state = manager.read_state()
    print(state.get("phase", "unknown"))


def cmd_explore_pick(manager: StateManager) -> None:
    state = manager.read_state_strict()
    exploration = state.get("exploration", {})
    priority = [
        "test_coverage",
        "error_handling",
        "security",
        "code_quality",
        "documentation",
        "architecture",
        "performance",
        "dx",
    ]
    for dim in priority:
        info = exploration.get(dim, {})
        if not info.get("audited"):
            print(dim)
            return
    scored = [
        (dim, exploration.get(dim, {}).get("score") or 0)
        for dim in priority
        if dim in exploration
    ]
    if scored:
        scored.sort(key=lambda item: item[1])
        print(scored[0][0])
    else:
        print(priority[0])


def cmd_explore_score(manager: StateManager, args: list[str]) -> None:
    if len(args) < 2:
        _die("Usage: conductor-state.py explore-score <project-dir> <dimension> <score>")
    dimension, score_raw = args[0], args[1]
    valid_dims = {
        "test_coverage",
        "error_handling",
        "security",
        "code_quality",
        "documentation",
        "architecture",
        "performance",
        "dx",
    }
    if dimension not in valid_dims:
        _die(f"unknown dimension: {dimension} (valid: {' '.join(sorted(valid_dims))})")
    try:
        score = float(score_raw)
    except ValueError:
        _die(f"score must be numeric, got: {score_raw}")

    state = manager.read_state_strict()
    if dimension in state.get("exploration", {}):
        state["exploration"][dimension]["audited"] = True
        state["exploration"][dimension]["score"] = score
    manager.write_state(state)
    print("ok")


def cmd_set_phase(manager: StateManager, args: list[str]) -> None:
    if len(args) < 1:
        _die("Usage: conductor-state.py set-phase <project-dir> <phase>")
    new_phase = args[0]
    valid_phases = {"directed", "exploring"}
    if new_phase not in valid_phases:
        _die(f"unknown phase: {new_phase} (valid: {' '.join(valid_phases)})")
    
    state = manager.read_state_strict()
    state["phase"] = new_phase
    state["phase_transition_reason"] = "manual override"
    manager.write_state(state)
    print(new_phase)


def cmd_lock(manager: StateManager) -> None:
    manager.acquire_lock()
    print(f"locked (PID {os.getpid()})")


def cmd_unlock(manager: StateManager) -> None:
    manager.release_lock()
    print("unlocked")


def main(argv: list[str]) -> int:
    if len(argv) <= 1 or argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0

    cmd = argv[1]
    project = Path(argv[2]) if len(argv) > 2 else Path(".")
    args = argv[3:]
    manager = StateManager(project)

    try:
        if cmd == "init":
            cmd_init(manager, args)
        elif cmd == "read":
            cmd_read(manager)
        elif cmd == "sprint-start":
            cmd_sprint_start(manager, args)
        elif cmd == "sprint-end":
            cmd_sprint_end(manager, args)
        elif cmd == "phase":
            cmd_phase(manager)
        elif cmd == "explore-pick":
            cmd_explore_pick(manager)
        elif cmd == "explore-score":
            cmd_explore_score(manager, args)
        elif cmd == "set-phase":
            cmd_set_phase(manager, args)
        elif cmd == "lock":
            cmd_lock(manager)
        elif cmd == "unlock":
            cmd_unlock(manager)
        else:
            _die(
                f"Unknown command: {cmd}. Use: init|read|sprint-start|sprint-end|phase|explore-pick|explore-score|set-phase|lock|unlock"
            )
    finally:
        manager.release_lock()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))

"""Pluggable CLI backends for autonomous workers.

Each backend module exposes the same surface so dispatch.py can swap
underlying CLIs without conditionals scattered through the codebase:

    cli_name() -> str
        Display name used in log lines / errors.

    is_available() -> bool
        Whether the CLI binary is on PATH.

    install_careful_hook(project_dir, window) -> str
        Side-effect: writes per-session hook config so the worker's
        destructive-command guard fires. Returns extra CLI args (e.g.
        ' --settings ...') to splice into the invocation, or "" when the
        backend reads its hook config from a file the script just wrote.

    build_command(extra_args) -> str
        Returns the shell line that runs the CLI with $PROMPT pre-set.

Selection is driven by `mode.backend` in user-config (env > project > global,
default "claude"). See dispatch.resolve_backend.
"""

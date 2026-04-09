#!/usr/bin/env bash
# update-check.sh — Check if a newer version of autonomous-skill is available.
#
# Output (one line, or nothing):
#   UPDATE_AVAILABLE <local> <remote>  — newer version exists
#   (nothing)                          — up to date, or check skipped/failed
#
# Cache: checks at most once per 60 minutes (cached in ~/.autonomous-skill/).
# Env overrides (for testing):
#   SKILL_DIR            — override auto-detected skill root
#   REMOTE_VERSION_URL   — override remote VERSION URL
#   STATE_DIR            — override state directory
set -euo pipefail

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$HOME/.autonomous-skill}"
CACHE_FILE="$STATE_DIR/last-update-check"
VERSION_FILE="$SKILL_DIR/VERSION"
REMOTE_URL="${REMOTE_VERSION_URL:-https://raw.githubusercontent.com/Sma1lboy/autonomous-skill/main/VERSION}"

# ─── Read local version ──────────────────────────────────────
LOCAL=""
if [ -f "$VERSION_FILE" ]; then
  LOCAL="$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$LOCAL" ]; then
  exit 0  # No VERSION file → skip
fi

# ─── Check cache freshness (60 min TTL) ──────────────────────
if [ -f "$CACHE_FILE" ]; then
  STALE=$(find "$CACHE_FILE" -mmin +60 2>/dev/null || true)
  if [ -z "$STALE" ]; then
    # Cache is fresh — replay result
    CACHED="$(cat "$CACHE_FILE" 2>/dev/null || true)"
    case "$CACHED" in
      UP_TO_DATE*) exit 0 ;;
      UPDATE_AVAILABLE*)
        # Verify local version hasn't changed since cache
        CACHED_LOCAL="$(echo "$CACHED" | awk '{print $2}')"
        if [ "$CACHED_LOCAL" = "$LOCAL" ]; then
          echo "$CACHED"
          exit 0
        fi
        ;;
    esac
  fi
fi

# ─── Fetch remote version ────────────────────────────────────
mkdir -p "$STATE_DIR"

REMOTE=""
REMOTE="$(curl -sf --max-time 5 "$REMOTE_URL" 2>/dev/null || true)"
REMOTE="$(echo "$REMOTE" | tr -d '[:space:]')"

# Validate: must look like a version number
if ! echo "$REMOTE" | grep -qE '^[0-9]+\.[0-9.]+$'; then
  echo "UP_TO_DATE $LOCAL" > "$CACHE_FILE"
  exit 0
fi

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "UP_TO_DATE $LOCAL" > "$CACHE_FILE"
  exit 0
fi

# Versions differ
echo "UPDATE_AVAILABLE $LOCAL $REMOTE" > "$CACHE_FILE"
echo "UPDATE_AVAILABLE $LOCAL $REMOTE"

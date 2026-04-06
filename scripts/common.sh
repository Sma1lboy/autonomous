#!/usr/bin/env bash
# common.sh — Shared utility functions for autonomous-skill scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# Layer: shared

die() { echo "ERROR: $*" >&2; exit 1; }

# Color support (when stdout is a terminal)
if [ -t 1 ]; then
  _CLR_RED=$'\033[0;31m'
  _CLR_GREEN=$'\033[0;32m'
  _CLR_YELLOW=$'\033[1;33m'
  _CLR_BLUE=$'\033[0;34m'
  _CLR_BOLD=$'\033[1m'
  _CLR_RESET=$'\033[0m'
else
  _CLR_RED='' _CLR_GREEN='' _CLR_YELLOW='' _CLR_BLUE='' _CLR_BOLD='' _CLR_RESET=''
fi

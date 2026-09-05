#!/usr/bin/env bash
# The commit hook accepts an executable path without arguments.
set -euo pipefail

exec .agents/skills/bot-instructions/scripts/bot-instructions check --staged

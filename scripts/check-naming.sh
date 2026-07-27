#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pattern='dank|DANK|Dank|Dms|DMS|dms|Aether|aether|DankMaterialShell|danklinux'
candidate_paths=(
  README.md
  quickshell/vshell
  config/vshell
  bin
  backend
  systemd
  themes
  AGENTS.md
  .agents/skills/vshell-dev
  docs/architecture
  docs/lock-crash-incident-2026-07-04.md
)

# Some paths (e.g. backend/) only exist once their phase lands; skip absent ones
# so the check works during incremental rollout.
paths=()
for p in "${candidate_paths[@]}"; do
  [[ -e "$p" ]] && paths+=("$p")
done

# themes/*/apps/* are curated files imported verbatim from omarchy; they may
# reference third-party plugins (e.g. the aether.nvim colorscheme) by name.
# config/vshell/nvim/colorschemes/** are third-party nvim colorscheme plugins
# vendored verbatim (with their own LICENSE); they keep their upstream naming.
# backend/ATTRIBUTION.md carries upstream license/lineage, which is exempt.
raw="$(rg -n -S --hidden \
  --glob '!quickshell/vshell/LICENSE' \
  --glob '!quickshell/vshell/LICENSE_CHANGE_12_11_2025.md' \
  --glob '!themes/*/apps/*' \
  --glob '!config/vshell/nvim/colorschemes/**' \
  --glob '!backend/ATTRIBUTION.md' \
  "$pattern" "${paths[@]}" || true)"

# Naming the upstream project in full is attribution, not residue: the About
# page and the docs' lineage notes both have to say where VGS came from. Only
# that exact spelling is exempt, so `DankBar`, `dms`, `danklinux` and friends
# are still caught — including on a line that also carries the attribution.
matches=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if printf '%s' "${line//DankMaterialShell/}" | rg -q -S "$pattern"; then
    matches+="$line"$'\n'
  fi
done <<< "$raw"

if [[ -n "$matches" ]]; then
  printf 'Legacy upstream naming residue found:\n%s' "$matches" >&2
  exit 1
fi

printf 'No legacy upstream naming residue found.\n'

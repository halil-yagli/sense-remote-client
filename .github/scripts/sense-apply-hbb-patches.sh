#!/usr/bin/env bash
# Sense Remote: libs/hbb_common is a git submodule of upstream RustDesk, so our changes to it
# cannot be committed here. They live as diffs in .github/patches/hbb_common/ and every job that
# compiles Rust applies them right after checkout. A patch that does not apply fails the job
# (a silently missing patch would ship a build without the fix).
# Run from the repository root.
set -euo pipefail

dir=libs/hbb_common
patches=(.github/patches/hbb_common/*.diff)
[[ -d "$dir" && -e "${patches[0]}" ]] || { echo "hbb_common or its patches are missing" >&2; exit 1; }

for p in "${patches[@]}"; do
  abs="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  if git -C "$dir" apply --check "$abs" 2>/dev/null; then
    git -C "$dir" apply "$abs"
    echo "applied: $p"
  elif git -C "$dir" apply --check --reverse "$abs" 2>/dev/null; then
    echo "already applied: $p"
  else
    echo "::error::hbb_common patch does not apply (submodule moved?): $p" >&2
    exit 1
  fi
done

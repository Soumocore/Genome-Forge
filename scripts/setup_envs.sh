#!/usr/bin/env bash
# Create the three conda environments (main tools, Medaka, BUSCO).
# Medaka and BUSCO live in their own environments because their dependency
# trees often conflict with the rest (this is what made "install everything
# at once" hang in the original guide).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if command -v mamba >/dev/null 2>&1; then PM=mamba
elif command -v conda >/dev/null 2>&1; then PM=conda
else
  echo "Neither mamba nor conda found. Install Miniforge first:" >&2
  echo "  https://github.com/conda-forge/miniforge" >&2
  exit 1
fi

for f in envs/bioinfo.yml envs/medaka.yml envs/busco.yml; do
  echo ">>> Creating environment from $f using $PM"
  "$PM" env create -f "$f" -y || "$PM" env update -f "$f" --prune
done
echo "Done. Activate the main environment with:  conda activate bioinfo"

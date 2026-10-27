#!/usr/bin/env bash
# Run SurfSLAM on one of OUR sequences (miniROV / PETRO), converted to their
# HDF5 by petro_reconstruction/scripts/s3_para_hdf5.py.
#
# Two things this script exists to pin down, both of which have already cost a
# run:
#
#   1. THE WORKING DIRECTORY. `system.log_dir_prefix` is "./outputs/", so the
#      results land next to wherever you launched from. Launching out of
#      examples/ puts them in examples/outputs/ and the previous runs in
#      outputs/ -- two sets of results, same names, no way to tell apart.
#      Here it is always the repo root.
#
#   2. THE BACKEND CONFIG. The scene file must override
#      tracker.backend_config_path, or cfg/defaults.yaml silently keeps the
#      pose graph on THEIR vehicle while only the frontend sees ours. This
#      script refuses to launch if the scene file does not override it.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CFG=${1:?uso: run_nosso_scene.sh <scene.yaml> [log]}
LOG=${2:-/tmp/surfslam_$(basename "$CFG" .yaml).log}

# PORTAO: o backend tem de apontar para a NOSSA calibracao.
cal=$(python3 -c "
import sys, yaml
c = yaml.safe_load(open('$CFG'))
back = (c.get('changes') or {}).get('tracker', {}).get('backend_config_path')
if not back:
    sys.exit('sem changes.tracker.backend_config_path -- o grafo de poses ia '
             'correr com os extrinsecos, as intrinsecas e a pressao '
             'atmosferica do veiculo DELES')
if back != c.get('calibration'):
    sys.exit(f'backend_config_path ({back}) != calibration ({c[\"calibration\"]}) '
             '-- nas ablacoes deles sao sempre o mesmo ficheiro')
print(back)
")
echo "portao: frontend e backend na mesma calibracao -> $cal"

cd "$REPO"
echo "cwd: $PWD   (as saidas vao para ./outputs/)"
python3 examples/run_surfslam.py "$CFG" > "$LOG" 2>&1
tail -3 "$LOG"

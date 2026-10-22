#!/usr/bin/env bash
#
# Non-interactive sibling of run.sh, for servers reached over SSH.
#
# run.sh always passes `-it` and ends in an interactive shell, so it cannot be
# driven from a CI job, a remote script, or a non-tty SSH session. This starts
# the same container detached and leaves it up; you then drive it with
# `docker exec`.
#
# The container is deliberately NOT `--rm`. install_pyturtlmap.sh builds into
# turtlmap/build-docker (inside the mounted repo, so it survives) but installs
# the module into $HOME/.local/lib/python3.*/site-packages, which belongs to
# the image. In a --rm container `import pyturtlmap` therefore fails on every
# launch, and surfslam/common/sensors.py imports it at module scope, so every
# examples/*.py dies during import.
#
#   ./docker/run_headless.sh              # start (or reuse) and build bindings
#   ./docker/run_headless.sh --recreate   # tear down and start clean
#   ./docker/run_headless.sh --stop       # stop and remove
#
# Then:
#   docker exec surfslam_$(whoami) python3 examples/stereo_inference.py \
#       cfg/tbnms/monohansett_boiler.yaml
#
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_TAG=surfslam:slam_$(whoami)   # must match IMAGE_TAG in build_user.sh
CONTAINER_NAME=surfslam_$(whoami)
CONTAINER_DATA_ROOT=/data
DATASET_PATHS_FILE="${SURF_DATASET_PATHS:-$SCRIPT_DIR/../cfg/dataset_paths.yaml}"

RECREATE=false
case "${1:-}" in
  --recreate) RECREATE=true ;;
  --stop) docker rm -f "$CONTAINER_NAME" 2>/dev/null && echo "removed $CONTAINER_NAME"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--recreate|--stop]" >&2; exit 2 ;;
esac

if ! docker image inspect "$IMAGE_TAG" > /dev/null 2>&1; then
  echo "Image $IMAGE_TAG not found; run docker/build_user.sh first." >&2
  exit 1
fi

$RECREATE && docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true

if [ "$(docker ps -q -f name="^${CONTAINER_NAME}$")" ]; then
  echo "Reusing running container $CONTAINER_NAME"
elif [ "$(docker ps -aq -f name="^${CONTAINER_NAME}$")" ]; then
  echo "Starting existing container $CONTAINER_NAME"
  docker start "$CONTAINER_NAME" > /dev/null
else
  DOCKER_OPTIONS=""
  DOCKER_OPTIONS+="-d "
  DOCKER_OPTIONS+="--name $CONTAINER_NAME "
  DOCKER_OPTIONS+="--entrypoint sleep "
  DOCKER_OPTIONS+="-v $SCRIPT_DIR/../:/home/$(whoami)/SurfSLAM "
  DOCKER_OPTIONS+="-v /etc/group:/etc/group:ro "
  DOCKER_OPTIONS+="-e SURF_IN_DOCKER=1 "
  DOCKER_OPTIONS+="-e SURF_DOCKER_DATA_ROOT=$CONTAINER_DATA_ROOT "
  DOCKER_OPTIONS+="--privileged "
  DOCKER_OPTIONS+="--gpus=all "
  DOCKER_OPTIONS+="-e NVIDIA_DRIVER_CAPABILITIES=all "
  DOCKER_OPTIONS+="--net=host "
  DOCKER_OPTIONS+="--runtime=nvidia "
  DOCKER_OPTIONS+="-u $(id -u):$(id -g) "
  DOCKER_OPTIONS+="-w /home/$(whoami)/SurfSLAM "

  # /dev/shm is tmpfs backed by RAM, so a size above the host's memory caps
  # nothing before the OOM killer. Default to half of RAM, never above 32G.
  SHM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 2048 ))
  [ "$SHM_MB" -gt 32768 ] && SHM_MB=32768
  DOCKER_OPTIONS+="--shm-size ${SURFSLAM_SHM_SIZE:-${SHM_MB}m} "

  # An unmatched glob stays literal in bash, so on a host with no /dev/video*
  # or an empty /mnt these would pass `--device=/dev/video*` to docker run,
  # which fails. Skip what does not exist.
  for cam in /dev/video*; do
    [ -e "$cam" ] || continue
    DOCKER_OPTIONS+="--device=${cam} "
  done

  for f in /mnt/*; do
    [ -e "$f" ] || continue
    DOCKER_OPTIONS+="-v $f:/mnt/$(basename $f) "
  done

  # Same dataset mounts as run.sh: each `key: /host/path` entry is bind-mounted
  # at $CONTAINER_DATA_ROOT/<key>. Keys left null, or pointing at something that
  # does not exist, are skipped.
  if [ -f "$DATASET_PATHS_FILE" ]; then
    echo "Dataset mounts (from $DATASET_PATHS_FILE):"
    while read -r key value; do
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"

      case "$value" in
        null|Null|NULL|"~"|"") continue ;;
      esac

      value="${value/#\~/$HOME}"

      if [ ! -d "$value" ]; then
        echo "  $key: skipped, $value is not a directory"
        continue
      fi

      DOCKER_OPTIONS+="-v $value:$CONTAINER_DATA_ROOT/$key "
      echo "  $key: $value -> $CONTAINER_DATA_ROOT/$key"
    done < <(
      sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$DATASET_PATHS_FILE" \
        | grep -E '^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*[^[:space:]]' \
        | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*/\1 /'
    )
  else
    echo "No $DATASET_PATHS_FILE - no dataset mounts. Copy cfg/dataset_paths.example.yaml to it."
  fi

  echo "Starting $CONTAINER_NAME"
  # shellcheck disable=SC2086
  docker run $DOCKER_OPTIONS "$IMAGE_TAG" infinity > /dev/null
fi

# entrypoint.sh is bypassed by --entrypoint sleep, so do its one real job here.
# No-op once the module is importable.
docker exec "$CONTAINER_NAME" bash docker/install_pyturtlmap.sh

docker exec "$CONTAINER_NAME" python3 -c "import pyturtlmap" \
  && echo "$CONTAINER_NAME ready; drive it with: docker exec $CONTAINER_NAME ..."

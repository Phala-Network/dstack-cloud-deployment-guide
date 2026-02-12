#!/bin/bash
set -euo pipefail

# Pinned source revisions (override via environment)
DSTACK_REV=${DSTACK_REV:-489136f8f8b1c1e5af3e7ca38e880bd0dd5079cf}
HELIOS_REV=${HELIOS_REV:-4a32ac1a9fbcf46386a497e4e0a7232ad1388762}

NAME=${1:?Usage: $0 <image-name>[:<tag>]}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building dstack-kms + helios image"
echo "  DSTACK_REV: ${DSTACK_REV}"
echo "  HELIOS_REV: ${HELIOS_REV}"
echo "  Image name: ${NAME}"

# Ensure buildkit builder exists
BUILDER_NAME=buildkit_20
if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    docker buildx create --use --driver-opt image=moby/buildkit:v0.20.2 --name "${BUILDER_NAME}"
fi

docker buildx build \
    --builder "${BUILDER_NAME}" \
    --build-arg "DSTACK_REV=${DSTACK_REV}" \
    --build-arg "HELIOS_REV=${HELIOS_REV}" \
    --output "type=docker,name=${NAME},rewrite-timestamp=true" \
    --progress=plain \
    "${SCRIPT_DIR}"

echo ""
echo "Built: ${NAME}"
echo "  dstack-kms from dstack-cloud@${DSTACK_REV:0:12}"
echo "  helios from helios@${HELIOS_REV:0:12}"

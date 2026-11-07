#!/bin/sh
# Builds out/Image in Docker (arm64). The kernel tree is kept in the v2mac-kbuild-src volume, so a config
# change only recompiles what changed. Set PROXY=http://host.docker.internal:<port> to download through one.
set -e
cd "$(dirname "$0")/.."
docker run --rm --platform linux/arm64 ${PROXY:+-e http_proxy=$PROXY -e https_proxy=$PROXY} \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1761091200}" \
  -v v2mac-kbuild-src:/build -v "$PWD":/work debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 /work/kernel/build.sh

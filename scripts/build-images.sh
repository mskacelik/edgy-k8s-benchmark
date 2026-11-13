#!/usr/bin/env bash
# Builds every benchmark image and tags it with the Edgy commit that went into it.
# An immutable tag over a mutable snapshot would not be reproducible, so the Edgy
# checkout must be clean and its revision is stamped on each image.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDGY_DIR="${EDGY_DIR:-/Users/mskaceli/dev/ibm/edgy}"
REGISTRY="${REGISTRY:-ghcr.io/mskacelik}"
# The cluster is x86_64; a Mac builds arm64 by default, which fails to exec there.
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH=false
NATIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=true ;;
    --native) NATIVE=true ;;
    --edgy) EDGY_DIR="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -d "$EDGY_DIR/.git" ]]; then
  echo "not a git checkout: $EDGY_DIR" >&2
  exit 1
fi

if [[ -n "$(git -C "$EDGY_DIR" status --porcelain)" ]]; then
  echo "Edgy working tree is dirty: $EDGY_DIR" >&2
  echo "Images must name exactly one Edgy build. Commit or stash first." >&2
  exit 1
fi

EDGY_SHA="$(git -C "$EDGY_DIR" rev-parse HEAD)"
TAG="$(git -C "$EDGY_DIR" rev-parse --short HEAD)"

echo "Edgy  $EDGY_DIR @ $TAG"
echo "Arch  $PLATFORM"
echo "Tag   $REGISTRY/<image>:$TAG"
echo

echo "==> installing Edgy"
(cd "$EDGY_DIR" && ./mvnw -q install -DskipTests)

BASE="$REGISTRY/bench-base:$TAG"

build() {
  local image="$1" dockerfile="$2"
  shift 2
  echo "==> $image"
  docker build \
    --platform "$PLATFORM" \
    --label "org.opencontainers.image.revision=$EDGY_SHA" \
    --label "org.opencontainers.image.source=https://github.com/mskacelik/edgy-k8s-benchmark" \
    -t "$image" -f "$dockerfile" "$@" "$DIR"
}

echo "==> $BASE"
docker build --platform "$PLATFORM" \
  --label "org.opencontainers.image.revision=$EDGY_SHA" \
  -t "$BASE" "$DIR/base"

build "$REGISTRY/bench-backend:$TAG" \
  "$DIR/backend-service/src/main/docker/Dockerfile.jvm" \
  --build-arg "BASE_IMAGE=$BASE"

build "$REGISTRY/bench-edgy-gateway:$TAG" \
  "$DIR/edgy-gateway/src/main/docker/Dockerfile.jvm" \
  --build-arg "BASE_IMAGE=$BASE" \
  --build-context "m2repo=$HOME/.m2/repository/org/acme"

build "$REGISTRY/bench-scg-gateway:$TAG" \
  "$DIR/scg-gateway/src/main/docker/Dockerfile" \
  --build-arg "BASE_IMAGE=$BASE"

if [[ "$NATIVE" == true ]]; then
  build "$REGISTRY/bench-edgy-gateway-native:$TAG" \
    "$DIR/edgy-gateway/src/main/docker/Dockerfile.native" \
    --build-context "m2repo=$HOME/.m2/repository/org/acme"
fi

if [[ "$PUSH" == true ]]; then
  for image in bench-base bench-backend bench-edgy-gateway bench-scg-gateway; do
    docker push "$REGISTRY/$image:$TAG"
  done
  [[ "$NATIVE" == true ]] && docker push "$REGISTRY/bench-edgy-gateway-native:$TAG"
fi

echo
echo "done, tag: $TAG"

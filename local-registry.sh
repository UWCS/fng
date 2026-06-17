#!/bin/bash
REGISTRY_DIR="$HOME/.local/share/container-registry"
mkdir -p "$REGISTRY_DIR"

podman kill local-registry 2>/dev/null
podman rm -f local-registry 2>/dev/null
podman unshare buildah unmount --all

podman run -d --name local-registry -p 5000:5000 \
    -v "$REGISTRY_DIR:/var/lib/registry:Z" \
    --restart=always \
    docker.io/library/registry:2

echo "Registry is running on localhost:5000"

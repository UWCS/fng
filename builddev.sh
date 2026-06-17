#!/bin/bash

./local-registry.sh

podman build -t localhost:5000/fng:dev .

podman push localhost:5000/fng:dev

echo "Build and push complete."

podman stop local-registry

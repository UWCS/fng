#!/bin/bash

./local-registry.sh

# build image and tag
podman build -t localhost:5000/fng:dev . --no-cache

podman push --tls-verify=false localhost:5000/fng:dev

echo "Build and push complete."

podman stop local-registry

# yes i know. cursed. fight me. also dcs update nvidia-ctk pls :<
# dcs uses nvidia-ctk v1.13.5 currently. the cdi specs generated always include chmod hooks which fail due to lack of perms
# (spec v0.5 for ref)
# v1.18 deprecates these hooks and doesn't include them by default
# generating the cdi spec gives the host binds needed to use the gpu in the container
# previously when this was done via distrobox, distrobox-init would loop through every possible thing it could find (incl. hardcoding)
# this is a much cleaner solution
# have to give podman "--cdi-spec-dir ./host" so it picks it up. default only looks in /etc/cdi which isn't present on the dcs fs
# if testing locally, most likely unnecessary once you have nvidia-ctk, worst case scenario you do e.g. sudo nvidia-ctk cdi generate one time
# with a cdi spec present, --device nvidia.com/gpu=all can be used when invoking podman
nvidia-ctk cdi generate | sed '
/^[[:space:]]*- args:/ {
  :loop
  N
  /path:/!b loop
  /chmod/d
}' > ./host/cdi.yaml

echo "Done."

#!/bin/bash

# build image and tag, squashing layers down to a unified layer to reduce redundancy
podman build -t localhost/fng:dev . --no-cache --squash-all

echo "Build complete. Compressing..."

# now the image is built and tagged, save as docker-archive (default) and compress to zst archive
# zst is significantly quicker to decompress than gzip
# main bottleneck is the nfs
    # running off of the nfs would be Bad:tm: anyway, but also cannot build directly on the nfs bc no xattr support since dcs uses nfs v3
    # so we copy the saved image to a given machine's local /var/tmp - bottlenecked by connection speed
    # this takes significantly longer the larger the image/its archive is and/or if using something slow like gzip
# -T0 tells zstd to use all cpu cores
# -3 indicates level 3 compression (default, ranges up to 22 - not recommended)
# up to -7 saves about 200mb, seems to be negligible after that. may adjust after further benchmarking
# current expectation is initial start for a given target machine, decompressing off the nfs into skopeo will take ~15s
# container startup post-pull is <10s
podman save localhost/fng:dev | zstd -T0 -3 > ./fng-dev.tar.zst

# yes i know. cursed. fight me. also dcs update nvidia-ctk pls :<
# dcs uses nvidia-ctk v1.13.5 currently. the cdi specs generated always include chmod hooks which fail due to lack of perms
# (spec v0.5 for ref)
# v1.18 deprecates these hooks and doesn't include them by default
# generating the cdi spec gives the host binds needed to use the gpu in the container
# previously when this was done via distrobox, distrobox-init would loop through every possible thing it could find (incl. hardcoding)
# this is a much cleaner solution

# second addition: patching https://github.com/NVIDIA/nvidia-container-toolkit/issues/682
# add from here into cdi for consistency more than anything
  # alternatives are e.g. mount in xsession, or create icd with "libnvidia-opencl.so.1" inside
  # removeable once nvidia-ctk 1.20 releases and dcs starts using it

# have to give podman "--cdi-spec-dir ./host" so it picks it up. default only looks in /etc/cdi which isn't present on the dcs fs
# if testing locally, most likely unnecessary once you have nvidia-ctk, worst case scenario you do e.g. sudo nvidia-ctk cdi generate one time
# with a cdi spec present, --device nvidia.com/gpu=all can be used when invoking podman
nvidia-ctk cdi generate | sed '
/^[[:space:]]*- args:/ {
  :loop
  N
  /path:/!b loop
  /chmod/d
}
/^[[:space::]]*mounts:/a\
  - containerPath: /etc/OpenCL/vendors/nvidia.icd\
    hostPath: /etc/OpenCL/vendors/nvidia.icd\
    options:\
    - ro\
    - nosuid\
    - nodev\
    - bind
' > ./host/cdi.yaml

echo "Done."

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

./genicd.sh

echo "Done."

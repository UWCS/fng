#!/bin/bash

if [ ! -d ./fng-disks ]; then
    echo "Pulling & building fng-disks..."
    git clone --depth=1 https://github.com/raven0034/fng-disks.git

    cd fng-disks
    make clean && make
    cd ..
else
    echo "fng-disks already present, remove (or run make clean) to rebuild..."
fi
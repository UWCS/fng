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
/^[[:space:]]*mounts:/a\
  - containerPath: /etc/OpenCL/vendors/nvidia.icd\
    hostPath: /etc/OpenCL/vendors/nvidia.icd\
    options:\
    - ro\
    - nosuid\
    - nodev\
    - bind\
  - containerPath: /usr/bin/nvidia-settings\
    hostPath: /usr/bin/nvidia-settings\
    options:\
    - ro\
    - nosuid\
    - nodev\
    - bind
' > ./host/cdi.yaml

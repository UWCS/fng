#!/bin/bash

# log per hostname - stops clashes when storing outside local tmp storage & allows easier dx of machine-specific quirks
exec > >(tee -i -a $(hostname)-$(id -u)-xsession.log) 2>&1

if [ -z "$DISPLAY" ]
then
    echo "DISPLAY is not set. Please set DISPLAY before running this script or start an X server."
    exit 1
fi

# attempt to unmount lingering volumes to mitigate container state issues (need to look into more)
# in theory this and removing the container shouldn't be needed any more, but need to test more
podman unshare buildah unmount --all
# remove the old container if it somehow hasn't already been removed
podman rm -f arch

# overlayfs storage for container (see storage.conf)
mkdir -p "/var/tmp/$USER"

image="localhost/fng:dev"

# if you want to check an image exists yourself, note that it doesn't output to stdout ie run the command then "echo $?"; 0 --> exists, 1 --> doesn't
if [ -f "/var/tmp/$USER/.ts" ] && [ "/var/tmp/$USER/.ts" -nt "./fng-dev.tar.zst" ] && podman image exists "$image"; then
    # .ts is a marker file. if the marker file:
        # - doesn't exist: copy image from nfs to /var/tmp, create marker file
        # - has an mtime older than/the same as the mtime of the zst: copy image, update mtime of marker file
        # - does exist and mtime is newer than the mtime of the zst: skip copy, just start container
    echo "Up-to-date image exists locally already, skipping copy..."
else
    echo "Up-to-date image not present locally, copying..."

    # clean up the old local image so it's not left dangling when untagged
    # more important for testing if you're rebuilding a lot bc the images can take up a fair chunk of space
    podman rmi -f "$image" 2>/dev/null

    # decompress zst and pipe into skopeo
    # podman load is awfully slow, skopeo is a sizeable chunk quicker, doesn't support oci-archives properly (podman save is docker-archive by default)
    # podman unshare to namespace the copying so permissions don't get lost
    # skopeo and zstd utils are pre-installed on the dcs machines
    # -T0 utilises all cores
    zstdcat -T0 ./fng-dev.tar.zst | podman unshare skopeo copy docker-archive:/dev/stdin containers-storage:localhost/fng:dev

    touch "/var/tmp/$USER/.ts"
fi

# --hostname implies private UTS namespace
# cap sys_admin currently currently exists so fuse mount will work (despite migrating to overlay, fuse is still used inside the container by e.g. xdg-document-portal)
# --systemd=always enforces systemd usage. /sbin/init is the entry point, /tmp/en as a hack for easily preserving set env vars
# --shm-size=0 does not set shared mem to 0, it just doesn't restrict it - also implies private IPC namespace
# --shm-size-systemd=0 same again, but important else podman will default to only 64MB
# --user 0:0 so container's PID 1 is owned by container's root, stops things exploding
    # startsession.service is then invoked with User=fng
# --network host for host network access - potentially better to namespace but may potentially break a lot (also to look into)
# --pids=-1 to remove container pid restriction
# --cdi-spec-dir needs to be set where /etc/cdi isn't present on the host (the case with the target)
    # --device nvidia.com/gpu=all is ref to the cdi spec (currently generated in builddev.sh)
        # cdi spec also contains the relevant binds for drivers
        # note that chmod hooks have to be removed from cdi spec (unnecessary and will fail since no perms)
            # deprecated and not gen'd by default in nvidia-ctk v1.18+ - dcs on v1.13.5 currently, hence workaround needed
# seccomp unconfined is more a failsafe (not in use on target currently)
# unmask so procfs can be mounted e.g. by bwrap - todo: find a minimal unmask set
    # on a related note sometimes this breaks anyway due to overmouting of /nvct-params as a tmpfs to /proc/driver/nvidia/params
    # doesn't seem to be an issue on target machines - on my machine it can safely just be unmounted
# locale & tz (now done with --tz) setting is needed else container will be american, and wrong time during bst
# generally moved env vars here for centralisation's sake
    # DISPLAY binds to the set display (usually :0 if running normally, rundev.sh uses :69 currently for running via Xephyr)
        # bind X11 socket so display actually functions as well
    # LANG and HOST_LOCALE similar for not defaulting to C.UTF-8
        # build also generates locales for en_US.UTF-8 else e.g. Steam will complain that it could start up quicker if it wasn't having to generate them
    # SHELL quietens Konsole complaining SHELL is '' then defaulting to /bin/bash anyway
    # __GL_SHADER_DISK_CACHE_SKIP_CLEANUP don't purge shaders so they don't have to be recompiled
        # clean-up happens by virtue of container removal so no longer-term impacts out of this
# podman added devpts mounts for this specific use case where it could conflict with host /dev being mounted
    # also needed so that shells incl. nested ones functional correctly
    # similar with setting $SHELL, else konsole will chuck an error at you
# currently /dev is mounted as a whole
    # hidraw* exists in the root of /dev - needs to be seen for controller support (incl. hotplugging)
    # targeted mounts would be better practice if feasible, issues largely mitigated by virtue of being rootless anyway
# /run/udev mount also required for controllers to work
    # udev rules are currently controlled by e.g. /etc/udev/rules.d/60-dcs-steam-input.rules on host - ask dcs tech to update
# reviewing /sys need
# otherwise minimal binds, minimal host exposure preferable
# pulse & pipewire mounts for audio
# keep the groups host user has e.g. video, input etc so access is same where bound
# --userns keep-id so the user in the container is mapped to the host user
    # gives the same theoretical caps, access etc as the host user
    # map as 1000:1000 since that's what is used elsewhere here
        # host user isn't always 1000 themselves
        # (tbf they're unlikely to be given the guiness world record is 122)
        # added since account now formally created rather than cheesing with home dir copy
        # breaks stuff like xdg-dirs-update otherwise
# --hooks-dir deliberately set to non-existent loc
    # on target, currently runs legacy oci nvidia-container-runtime-hook otherwise, which will crash
    # podman cries if hooks-dir is left empty for some reason
# --rm to remove the container once it exits - see storage.conf for note on overlay about this
# unified under podman run rather than previous separate create & exec
podman run --rm \
    --hostname $(hostname) \
    --name "arch" \
    --cap-add=SYS_ADMIN \
    --systemd=always \
    --shm-size=0 \
    --shm-size-systemd=0 \
    --user 0:0 \
    --network host \
    --pids-limit=-1 \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    --security-opt unmask=ALL \
    --cdi-spec-dir=./host \
    --device nvidia.com/gpu=all \
    --tz="Europe/London" \
    --env "DISPLAY=$DISPLAY" \
    --env "LANG=en_GB.UTF-8" \
    --env "HOST_LOCALE=en_GB.UTF-8" \
    --env "SHELL=/bin/bash" \
    --env "HOME=/home/fng" \
    --env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" \
    --env "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" \
    --env "XDG_SESSION_TYPE=x11" \
    --env "XDG_RUNTIME_DIR=/run/user/1000" \
    --env "PULSE_SERVER=unix:/run/user/1000/pulse/native" \
    --env "XAUTHORITY=/tmp/.Xauthority" \
    --hooks-dir="$(pwd)/garb" \
    --mount type=devpts,target=/dev/pts \
    --volume /dev:/dev:rslave \
    --volume /sys:/sys:rslave \
    --volume /run/udev:/run/udev:rslave \
    --volume /etc/machine-id:/etc/machine-id:ro \
    --volume /etc/hosts:/etc/hosts:ro \
    --volume /etc/resolv.conf:/etc/resolv.conf:ro \
    --volume /etc/nsswitch.conf:/etc/nsswitch.conf:ro \
    --volume "/tmp/.X11-unix:/tmp/.X11-unix:ro" \
    --volume "$XDG_RUNTIME_DIR/pipewire-0:/run/user/1000/pipewire-0" \
    --volume "$XDG_RUNTIME_DIR/pulse:/run/user/1000/pulse" \
    --volume "$XAUTHORITY:/tmp/.Xauthority" \
    --userns keep-id:uid=1000,gid=1000 \
    --group-add keep-groups \
    --entrypoint /bin/bash \
    $image \
    -c "env > /etc/environment && exec /sbin/init"

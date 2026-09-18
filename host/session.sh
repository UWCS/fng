#!/bin/bash

# normalise path to our parent directory
cd "$(dirname "$0")"/..

# log per hostname - stops clashes when storing outside local tmp storage & allows easier dx of machine-specific quirks
exec > >(tee -i -a $(hostname)-$(id -u)-xsession.log) 2>&1
echo $(date)

HOST_XDG_SESSION_ID="$XDG_SESSION_ID"
PROXY_DIR="$XDG_RUNTIME_DIR/fng"
# don't want to expose the entirety of the system bus socket
PROXY_SOCK="$PROXY_DIR/login1-bus"

# make sure proxy can actually be created
mkdir -p "$PROXY_DIR"
chmod 700 "$PROXY_DIR"
# clean-up old socket if present
rm -f "$PROXY_SOCK" 2>/dev/null

# see active login seat in logs for debugging
loginctl show-session "$XDG_SESSION_ID" -p Id -p User -p Seat -p Active -p VTNr -p Type -p Class

# rough prereq setup of Rocky 10:
## sudo dnf install epel-release -y
## sudo dnf config-manager --enable crb
## sudo dnf groupinstall "Development Tools" -y
## sudo dnf install kernel-devel-matched kernel-headers -y
##
##
## curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
##
## sudo dnf clean expire-cache
## curl -LO https://download.nvidia.com/XFree86/Linux-x86_64/595.99.02/NVIDIA-Linux-x86_64-595.99.02.run
## chmod +x ./NVIDIA-Linux-x86_64-595.99.02.run
## sudo ./NVIDIA-Linux-x86_64-595.99.02.run
## sudo dnf install nvidia-settings vulkan-tools egl-utils clinfo nvidia-container-toolkit-1.20.0-1 nvidia-container-toolkit-base-1.20.0-1 libnvidia-container-tools-1.20.0.1 libnvidia-container1-1.20.0.1 libglvnd-devel
##
## sudo mokutil --import /var/lib/dkms/mok.pub
## sudo grubby --args="nouveau.modeset=0 rd.driver.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1" --update-kernel=ALL
##
## sudo dracut -f --regenerate-all
## sudo reboot now

## fng-container-session.desktop should be present under /usr/share/wayland-sessions/
    ## root ownership, 644 perms sufficient
## wayland-userscript should be present under /usr/bin
    ## root ownership, 755 perms sufficient
    ## if issues re SELinux: sudo chcon -u system_u /usr/bin/wayland-userscript
## session.sh is the replacement for .xsession, for the avoidance of doubt

# rationale regarding proxy:
# - minimal loss to isolation by only exposing the part(s) of the D-Bus API needed
# - an unprivileged container needs to interact with the host systemd-logind instance
# - this is because systemd-logind is responsible for the active graphical session on a seat (e.g. seat0)
# - for compositing using DRM Kernel Modeset, we need to take exclusive control of the active graphical session
# - the container does not own the host seat nor VT
# - proxy allows issuing TakeDevice and TakeControl to login1 to bypass this
# - when logging in via e.g. GDM, the host session has session ID, a seat, VT etc
# - KWin (or whichever other compositor) effectively needs to estabilish that it belongs to the host session (else TakeControl will fail)
# - the container still retains its own session bus separately from this

# note: seatd is an interesting alternative, providing a bindable seat socket. however, not supported upstream by kwin.

# semi-connected: sometimes GDM has issues with teardown & handoff of session in some envs
    # - usually this has meant a soft-lock with blank screen and often no response to input
    # - observed outside of containers as well e.g. Plasma natively
    # - kinda dumb hack but i found adding `sleep 1` to /etc/gdm/PreSession/Default the most effective workaround
    # - sometimes it won't soft-lock entirely but gdm often breaks if there's an issue that causes a return to the login screen
    # - in a separate tty, try run `faillock --user <USER> --reset`, or if this fails, `systemctl restart gdm`

# look at narrowing filter more
# todo: possible split-strat for host vs container sys dbus since e.g. some polkit issues
# also todo: see about scoping env var injection better
xdg-dbus-proxy unix:path=/run/dbus/system_bus_socket $PROXY_SOCK --filter --talk=org.freedesktop.login1 &

proxy_pid=$!

cleanup() {
    kill "$proxy_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while [ ! -S "$PROXY_SOCK" ]; do
    echo "Waiting on D-Bus Proxy to become available..."
    sleep 1
done

# if nesting compositor. don't recommend bc perf hits + wl prot incompatibilities
# can nest kwin (container) under kwin (host) but kinda heavyweight
# Cage on host didn't work for me, Weston did but would have issue with atomic modeset
# best is direct control
# 
#if [ -z "$WAYLAND_DISPLAY" ]
#then
#    echo "WAYLAND_DISPLAY is not set. Please make sure a Wayland compositor (e.g. Weston) is running."
#    exit 1
#fi

# attempt to unmount lingering volumes to mitigate container state issues (need to look into more)
# in theory this and removing the container shouldn't be needed any more, but need to test more
podman unshare buildah unmount --all
# remove the old container if it somehow hasn't already been removed
podman rm -f arch

# overlayfs storage for container (see storage.conf)
mkdir -p "/var/tmp/$USER"

## comment out when changes are good for prod
DEV=1

# separated out bc it's annoying on your own system where you don't have an NFS in the way
if [ -n "$NDEV" ]; then
    echo "Running fng:dev"
    image="fng:dev"

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
        # podman unshare to namespace the copying so permissions don't get lost (IMPORTANT - this applies for ALL build/pull workflows, hence applied below too)
        # skopeo and zstd utils are pre-installed on the dcs machines
        # -T0 utilises all cores
        zstdcat -T0 ./fng-dev.tar.zst | podman unshare skopeo copy docker-archive:/dev/stdin containers-storage:"$image"

        touch "/var/tmp/$USER/.ts"
    fi
else
    if [ -n "$DEV" ]; then
        image="localhost/fng:dev"
    else
        # base
        image="fng:latest"

        # image pushed to GHCR
        remote_image="docker://ghcr.io/uwcs/$image"

        # image on NFS
        airport_image="oci:$(pwd)/$image"

        # image on specific PC's local disk
        local_image="containers-storage:$image"

        # hash of HEAD commit from checked-out branch/commit on NFS
        airport_hash=$(git rev-parse HEAD 2>/dev/null)

        # commit hash GHCR image was built against
        remote_hash=$(skopeo inspect "$remote_image" --format '{{ index .Labels "uwcs.fng.commit" }}' 2>/dev/null)

        if [[ -n "$remote_hash" && "$airport_hash" != "$remote_hash" ]]; then
            # re concurrency, only one at a time will succeed here hence lock
            if mkdir "$(pwd)/gitup.lock" 2>/dev/null; then
                # if script dies then trap cleans up so no infinite loop on next run
                trap 'rm -rf "$(pwd)/gitup.lock" 2>/dev/null' EXIT

                git fetch origin >/dev/null 2>&1
                git reset --hard

                # stop untracked stuff getting in the way
                # run in dev mode if you're developing in a live instance
                git clean -f

                # checkout specific hash corresponding to img build
                git checkout "$remote_hash"

                # mod to add force-override for e.g. storage.conf changes?
                ./install.sh

                rm -rf "$(pwd)/gitup.lock" 2>/dev/null
                trap - EXIT

                # replace execution environment with self - or rather, *updated* self. ie so proc can survive xsession change
                exec bash "$0" "$@"
            else
                echo "Waiting for gitup.lock to be released before script restart"
                while [[ -d "$(pwd)/gitup.lock" ]]; do
                    sleep 2
                done

                # restart on followers too
                exec bash "$0" "$@"
            fi
        fi

        remote_digest=$(skopeo inspect "$remote_image" --format "{{.Digest}}" 2>/dev/null)
        airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)
        local_digest=$(skopeo inspect "$local_image" --format "{{.Digest}}" 2>/dev/null)

        # we only need to pull an updated image from GHCR if we don't have the updated image on the NFS already
        if [[ -n "$remote_digest" && "$remote_digest" == "$airport_digest" && ! -d "$(pwd)/update.lock" ]]; then
            echo "NFS image same as remote, skipping download"
        else
            # same idea here, one PC holds a "lock" whilst pulling updated image
            if mkdir "$(pwd)/update.lock" 2>/dev/null; then
                trap 'rm -rf "$(pwd)/update.lock" 2>/dev/null' EXIT

                echo "Updated image upstream, downloading..."
                if podman unshare skopeo copy "$remote_image" "$airport_image"; then
                    echo "Success!"
                else
                    echo "Lack of success!"
                fi

                rm -rf "$(pwd)/update.lock" 2>/dev/null
                trap - EXIT
            else
                echo "Waiting for $(pwd)/update.lock to be released to pull updated image"

                while [[ -d "$(pwd)/update.lock" ]]; do
                    sleep 2
                done
            fi
        fi

        airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)

        # don't need to pull NFS --> local if updated image already present locally
        # (ie expectation is that updated GHCR image flow will initially take up to a couple of mins, but subsequently would be ~5 seconds for each target mch with the img present locally already)
        if [[ -n "$airport_digest" && "$local_digest" == "$airport_digest" ]]; then
            echo "Local image same as NFS image, skipping pull..."
        else
            echo "Updated image on NFS, pulling locally..."
            podman unshare skopeo copy "$airport_image" "$local_image"
        fi
    fi
fi

## todo: figure out auto-updating cdi if e.g. drivers get updated - pref don't want to regenerate every time
if [[ ! -f "$(pwd)/host/cdi.yaml" ]]; then
    ./genicd.sh
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

# todo: tidy up extra env vars from testing
podman run \
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
    --env "LANG=en_GB.UTF-8" \
    --env "HOST_LOCALE=en_GB.UTF-8" \
    --env "SHELL=/bin/bash" \
    --env "HOME=/home/fng" \
    --env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" \
    --env "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" \
    --env "GTK_CSD=1" \
    --env "GBM_BACKEND=nvidia-drm" \
    --env "__GLX_VENDOR_LIBRARY_NAME=nvidia" \
    --env "__NV_PRIME_RENDER_OFFLOAD=1" \
    --env "__VK_LAYER_NV_optimus=NVIDIA_only" \
    --env "VK_DRIVER_FILES=/etc/vulkan/icd.d/nvidia_icd.json" \
    --env "XDG_SESSION_TYPE=wayland" \
    --env "XDG_RUNTIME_DIR=/run/user/1000" \
    --env "PULSE_SERVER=unix:/mnt/host_sockets/pulse/native" \
    --env "KWIN_FORCE_SW_CURSOR=1" \
    --env "HOST_XDG_SESSION_ID=$HOST_XDG_SESSION_ID" \
    --volume "$PROXY_DIR:/mnt/host_sockets/fng" \
    --hooks-dir="$(pwd)/garb" \
    --mount type=devpts,target=/dev/pts \
    --volume /dev:/dev:rslave \
    --volume /sys:/sys:rslave \
    --volume /run/udev:/run/udev:rslave \
    --volume /etc/machine-id:/etc/machine-id:ro \
    --volume /etc/hosts:/etc/hosts:ro \
    --volume /etc/resolv.conf:/etc/resolv.conf:ro \
    --volume "$XDG_RUNTIME_DIR/pipewire-0:/mnt/host_sockets/pipewire-0" \
    --volume "$XDG_RUNTIME_DIR/pulse:/mnt/host_sockets/pulse" \
    --userns keep-id:uid=1000,gid=1000 \
    --group-add keep-groups \
    --entrypoint /bin/bash \
    $image \
    -c "env > /etc/environment && exec /sbin/init"

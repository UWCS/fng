#!/bin/bash

# splash optional, shouldn't prevent login if it gets lost on holiday in the bahamas (or smth)
SPLASH_DIR="$(pwd)/host/fng-splash"
status_helper="$SPLASH_DIR/status.sh"
splash_app="$SPLASH_DIR/fng-splash.py"
if [[ -r "$status_helper" ]]; then
    source "$status_helper"
else
    status() { :; }
fi

stop_job() {
    [[ -n "$1" ]] || return 0
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# outer launcher owns splash & logging, inner xsession can replace itself post update
if [[ -z "$FNG_XSESSION_WORKER" ]]; then
    exec > >(tee -i -a "$(hostname)-$(id -u)-xsession.log") 2>&1
    echo "$(date)"

    if [[ -z "$DISPLAY" ]]; then
        echo "DISPLAY is not set. Please set DISPLAY before running this script or start an X server."
        exit 1
    fi

    exec 3>&1 4>&2
    export FNG_XSESSION_WORKER=1
    export FNG_SPLASH_STATUS= FNG_SPLASH_LOG=
    splash_dir=
    splash_pid=
    worker_pid=

    cleanup_splash() {
        stop_job "$worker_pid"
        stop_job "$splash_pid"
        [[ -z "$splash_dir" ]] || rm -rf -- "$splash_dir"
    }
    trap cleanup_splash EXIT

    if [[ -r "$splash_app" && -r "$status_helper" && -n "$XDG_RUNTIME_DIR" ]]; then
        splash_dir=$(mktemp -d "$XDG_RUNTIME_DIR/fng-splash.XXXXXXXX")
        if [[ -n "$splash_dir" ]]; then
            export FNG_SPLASH_STATUS="$splash_dir/status.ini"
            export FNG_SPLASH_LOG="$splash_dir/startup.log"
            touch "$FNG_SPLASH_LOG"
            status busy "Starting FNG..."
            GDK_BACKEND=x11 DISPLAY="$DISPLAY" python3 "$splash_app" --fullscreen --status-file "$FNG_SPLASH_STATUS" --log-file "$FNG_SPLASH_LOG" &
            splash_pid=$!
        fi
    else
        echo "FNG splash unavailable; continuing without it"
    fi

    if [[ -n "$FNG_SPLASH_LOG" ]]; then
        bash "$0" "$@" <&0 > >(tee -i -a "$FNG_SPLASH_LOG") 2>&1 &
    else
        bash "$0" "$@" <&0 &
    fi
    worker_pid=$!
    wait "$worker_pid"
    rc=$?
    worker_pid=

    # startup failures visible briefly/until dismissed
    if [[ -n "$splash_pid" ]] && ! grep -qx 'state=ready' "$FNG_SPLASH_STATUS" 2>/dev/null; then
        if ! grep -qx 'state=error' "$FNG_SPLASH_STATUS" 2>/dev/null; then
            status error "FNG exited before the desktop was ready" "Session exited with status $rc."
        fi
        for ((i=0; i<60; i++)); do
            kill -0 "$splash_pid" 2>/dev/null || break
            sleep 1
        done
    fi
    exit "$rc"
fi

owned_lock=
step_pid=
podman_pid=
readiness_pid=
removable_bridge_pid=

release_lock() {
    if [[ -n "$owned_lock" ]]; then
        rm -rf -- "$owned_lock" || return 1
        owned_lock=
    fi
}

# 0 --> owned by us, 1 --> not, 2 --> emotional damage
acquire_lock() {
    if mkdir "$1" 2>/dev/null || { [[ ! -d "$1" ]] && mkdir "$1" 2>/dev/null; }; then
        owned_lock=$1
        return 0
    fi
    [[ -d "$1" ]] && return 1
    return 2
}

cleanup_worker() {
    # run_step creates a process group so cancellation includes pipelines
    if [[ -n "$step_pid" ]]; then
        kill -TERM -- "-$step_pid" 2>/dev/null || true
        # don't release lock until cancellation handled properly
        for ((i=0; i<50; i++)); do
            kill -0 -- "-$step_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 -- "-$step_pid" 2>/dev/null; then
            echo "Setup process group has not exited, leaving any owned update lock for inspection" >&2
            owned_lock=
        else
            wait "$step_pid" 2>/dev/null || true
        fi
    fi
    for pid in "$readiness_pid" "$removable_bridge_pid" "$podman_pid"; do
        stop_job "$pid"
    done
    release_lock || true
}
trap cleanup_worker EXIT

fail() {
    local rc=$1 message=$2 detail=${3:-}
    echo "$message${detail:+: $detail} (exit $rc)" >&2
    status error "$message" "${detail:-Exit status $rc.}"
    exit "$rc"
}

# waitable group, can be termed
run_step() {
    local rc
    set -m
    (set +m; "$@") <&0 &
    step_pid=$!
    set +m
    wait "$step_pid"
    rc=$?
    step_pid=
    return "$rc"
}

fng_copy() {
    local message=$1 verb=$2
    shift 2
    if [[ -r "$SPLASH_DIR/copy-progress.py" ]] && [[ -n "$FNG_SPLASH_STATUS" || -n "$FNG_COPY_SHARED_STATUS" ]]; then
        python3 "$SPLASH_DIR/copy-progress.py" "$message" "$verb" "$@"
    else
        status busy "$message"
        "$@"
    fi
}

status busy "Preparing session..." "Cleaning up previous container state"

# attempt to unmount lingering volumes to mitigate container state issues (need to look into more)
# in theory this and removing the container shouldn't be needed any more, but need to test more
run_step podman unshare buildah unmount --all
# remove the old container if it somehow hasn't already been removed
run_step podman rm -f arch

# overlayfs storage for container (see storage.conf)
mkdir -p "/var/tmp/$USER" || fail "$?" "Unable to prepare local storage"

HOST_XDG_SESSION_ID="$XDG_SESSION_ID"
PROXY_DIR="$XDG_RUNTIME_DIR/fng"

mkdir -p "$PROXY_DIR" || fail "$?" "Unable to prepare session sockets"

#DEV=1

if [ -n "$DEV" ]; then
    status busy "Checking development image..."
    echo "Running fng:dev"
    image="fng:dev"

    # if you want to check an image exists yourself, note that it doesn't output to stdout ie run the command then "echo $?"; 0 --> exists, 1 --> doesn't
    [[ -r ./fng-dev.tar.zst ]] || fail 1 "Unable to import dev image" "fng-dev.tar.zst is missing or unreadable."
    if [ -f "/var/tmp/$USER/.ts" ] && [ "/var/tmp/$USER/.ts" -nt "./fng-dev.tar.zst" ] && podman image exists "$image"; then
        # .ts is a marker file. if the marker file:
            # - doesn't exist: copy image from nfs to /var/tmp, create marker file
            # - has an mtime older than/the same as the mtime of the zst: copy image, update mtime of marker file
            # - does exist and mtime is newer than the mtime of the zst: skip copy, just start container
        echo "Up-to-date image exists locally already, skipping copy..."
    else
        status busy "Importing dev image..." "Removing previous image"
        echo "Up-to-date image not present locally, copying..."

        # clean up the old local image so it's not left dangling when untagged
        # more important for testing if you're rebuilding a lot bc the images can take up a fair chunk of space
        rm -f -- "/var/tmp/$USER/.ts" || fail "$?" "Unable to invalidate dev image cache"
        if podman image exists "$image"; then
            run_step podman rmi -f "$image" || fail "$?" "Unable to remove previous dev image"
        fi

        # decompress zst and pipe into skopeo
        # podman load is awfully slow, skopeo is a sizeable chunk quicker, doesn't support oci-archives properly (podman save is docker-archive by default)
        # podman unshare to namespace the copying so permissions don't get lost (IMPORTANT - this applies for ALL build/pull workflows, hence applied below too)
        # skopeo and zstd utils are pre-installed on the dcs machines
        # -T0 utilises all cores
        import_dev() {
            set -o pipefail
            zstdcat -T0 ./fng-dev.tar.zst | fng_copy "Importing dev image..." Importing podman unshare skopeo copy docker-archive:/dev/stdin containers-storage:"$image"
        }
        run_step import_dev || fail "$?" "Unable to import dev image" "See diagnostic logs for details."
        touch "/var/tmp/$USER/.ts" || fail "$?" "Unable to record dev image import"
    fi
else
    # base
    image="fng:latest"

    # image pushed to GHCR
    remote_image="docker://ghcr.io/uwcs/$image"

    # image on NFS
    airport_image="oci:$(pwd)/$image"

    # image on specific PC's local disk
    local_image="containers-storage:$image"

    git_lock="$(pwd)/gitup.lock"
    image_lock="$(pwd)/update.lock"
    status busy "Checking for updates..."

    # hash of HEAD commit from checked-out branch/commit on NFS
    airport_hash=$(git rev-parse HEAD 2>/dev/null)

    # commit hash GHCR image was built against
    remote_hash=$(skopeo inspect "$remote_image" --format '{{ index .Labels "uwcs.fng.commit" }}' 2>/dev/null)

    if [[ -n "$remote_hash" && "$airport_hash" != "$remote_hash" ]]; then
        # re concurrency, only one at a time will succeed here hence lock
        if acquire_lock "$git_lock"; then

            status busy "Updating FNG launcher..."

            run_step git fetch origin || fail "$?" "Unable to update FNG launcher"
            run_step git reset --hard || fail "$?" "Unable to update FNG launcher"

            # stop untracked stuff getting in the way
            # run in dev mode if you're developing in a live instance
            run_step git clean -f || fail "$?" "Unable to update FNG launcher"

            # checkout specific hash corresponding to img build
            run_step git checkout "$remote_hash" || fail "$?" "Unable to update FNG launcher"

            # mod to add force-override for e.g. storage.conf changes?
            run_step ./install.sh || fail "$?" "Unable to install FNG launcher"

            release_lock || fail "$?" "Unable to release launcher update lock"

            # replace execution environment with self - or rather, *updated* self. ie so proc can survive xsession change
            exec bash "$0" "$@"
        else
            [[ $? == 1 ]] || fail 1 "Unable to acquire launcher update lock"
            status busy "Waiting for another PC..." "Launcher is being updated"
            echo "Waiting for gitup.lock to be released before script restart"
            while [[ -d "$git_lock" ]]; do
                sleep 2
            done

            # restart on followers too
            exec bash "$0" "$@"
        fi
    fi

    status busy "Checking container images..." "Comparing GHCR, NFS and the local cache"
    remote_digest=$(skopeo inspect "$remote_image" --format "{{.Digest}}" 2>/dev/null)
    airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)
    local_digest=$(skopeo inspect "$local_image" --format "{{.Digest}}" 2>/dev/null)

    # serialise updates & re-check cache after taking lock (previous holder didn't inherently succeed just bc it exited)
    [[ -n "$remote_digest" ]] || fail 1 "Unable to check FNG update" "Could not read the GHCR image digest."
    while :; do
        if [[ ! -d "$image_lock" && -n "$airport_digest" && "$remote_digest" == "$airport_digest" ]]; then
            echo "NFS image same as remote, skipping download"
            break
        fi
        acquire_lock "$image_lock"
        lock_rc=$?
        if [[ $lock_rc == 0 ]]; then
            airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)
            if [[ "$remote_digest" != "$airport_digest" ]]; then
                echo "Updated image upstream, downloading..."
                FNG_COPY_SHARED_STATUS="$owned_lock/progress.ini" run_step fng_copy "Downloading FNG update..." Downloading podman unshare skopeo copy "$remote_image" "$airport_image" || fail "$?" "Unable to download FNG update" "See diagnostic logs for details."
                airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)
                [[ -n "$airport_digest" ]] || fail 1 "Unable to verify downloaded FNG image"
            else
                echo "NFS image same as remote, skipping download"
            fi
            release_lock || fail "$?" "Unable to release image update lock"
            break
        fi
        [[ $lock_rc == 1 ]] || fail 1 "Unable to acquire image update lock"
        status busy "Waiting for FNG update..." "Another PC is downloading the image to shared storage"
        previous_snapshot=
        echo "Waiting for $image_lock to be released to pull updated image"

        while [[ -d "$image_lock" ]]; do
            shared_snapshot=$(cat "$image_lock/progress.ini" 2>/dev/null) || shared_snapshot=
            if [[ "$shared_snapshot" != "$previous_snapshot" ]]; then
                previous_snapshot=$shared_snapshot
                shared_detail=$(sed -n 's/^detail=//p' <<< "$shared_snapshot" | head -n 1)
                shared_progress=$(sed -n 's/^progress=//p' <<< "$shared_snapshot" | head -n 1)
                [[ "$shared_progress" =~ ^([0-9]{1,3}(\.[0-9]+)?|-1(\.0+)?)$ ]] || shared_progress=-1
                status busy "Waiting for FNG update..." "${shared_detail:-Another PC is downloading the image to shared storage}" "$shared_progress"
            fi
            sleep 2
        done
        airport_digest=$(skopeo inspect "$airport_image" --format "{{.Digest}}" 2>/dev/null)
    done

    # don't need to pull NFS --> local if updated image already present locally
    # (ie expectation is that updated GHCR image flow will initially take up to a couple of mins, but subsequently would be ~5 seconds for each target mch with the img present locally already)
    if [[ -n "$airport_digest" && "$local_digest" == "$airport_digest" ]]; then
        echo "Local image same as NFS image, skipping pull..."
    else
        echo "Updated image on NFS, pulling locally..."
        run_step fng_copy "Pulling FNG update..." Copying podman unshare skopeo copy "$airport_image" "$local_image" || fail "$?" "Unable to pull FNG update" "See diagnostic logs for details."    fi
    fi
fi

status busy "Preparing environment..." "Checking NVIDIA drivers and device bindings"

## if condition is met either no CDI spec or drivers got quietly updated again
## e.g. if driver version is 595.99.02, correct CDI spec will have .so.595.99.02 entries
## lack of matches --> version mismatch --> regen
if [[ ! -f "$(pwd)/host/cdi.yaml" ]] || ! grep -Fq -- "$(cat /sys/module/nvidia/version)" host/cdi.yaml; then
    echo "Regenerating CDI spec"
    run_step ./genicd.sh || fail "$?" "Unable to prepare environment" "CDI generation failed."
fi

## if not present, pull fng-disks down - pref CI & versioning in future
## intended usage means fng-disks won't present initially on host - trying to avoid submoduling atm
status busy "Preparing removable storage..."
run_step ./get-fng-disks.sh || fail "$?" "Unable to prepare removable storage"

status busy "Starting environment, may take a minute..."

# Normal log level by default; explicit debug goes to the permanent host log.
podman_launch=(podman)
if [[ "${FNG_PODMAN_DEBUG:-0}" == 1 ]]; then
    podman_launch+=(--log-level=debug)
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
"${podman_launch[@]}" run --rm \
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
    --device /dev/snd \
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
    --env "PULSE_SERVER=unix:/mnt/host_sockets/pulse/native" \
    --env "PIPEWIRE_RUNTIME_DIR=/mnt/host_sockets" \
    --env "XAUTHORITY=/tmp/.Xauthority" \
    --env "HOST_XDG_SESSION_ID=$HOST_XDG_SESSION_ID" \
    --volume "$PROXY_DIR:/mnt/host_sockets/fng" \
    --hooks-dir="$(pwd)/garb" \
    --mount type=devpts,target=/dev/pts \
    --volume /dev:/dev:rslave \
    --volume /sys:/sys:rslave \
    --volume /run/udev:/run/udev:rslave \
    --volume /etc/machine-id:/etc/machine-id:ro \
    --volume /etc/hosts:/etc/hosts:ro \
    --volume "$(pwd)/fng-disks/bin/fng-disks:/usr/bin/fng-disks" \
    --volume /etc/resolv.conf:/etc/resolv.conf:ro \
    --volume "/tmp/.X11-unix:/tmp/.X11-unix:ro" \
    --volume "$XDG_RUNTIME_DIR/pipewire-0:/mnt/host_sockets/pipewire-0:ro" \
    --volume "$XDG_RUNTIME_DIR/pulse:/mnt/host_sockets/pulse:ro" \
    --volume "$XAUTHORITY:/tmp/.Xauthority" \
    --userns keep-id:uid=1000,gid=1000 \
    --group-add keep-groups \
    --entrypoint /bin/bash \
    "$image" \
    -c "env > /etc/environment && exec /sbin/init" >&3 2>&4 &

podman_pid=$!

while [ "$(podman inspect -f '{{.State.Running}}' arch 2>/dev/null)" != "true" ]; do
    if ! kill -0 "$podman_pid" 2>/dev/null; then
        wait "$podman_pid"
        rc=$?
        podman_pid=
        exit "$rc"
    fi
    sleep 0.5
done

status busy "Initialising FNG..." "Connecting removable storage"

CONTAINER_PID="$(podman inspect -f '{{.State.Pid}}' arch)" || fail "$?" "Unable to inspect FNG container"
[[ "$CONTAINER_PID" =~ ^[1-9][0-9]*$ ]] || fail 1 "FNG container is not running"

{
    echo
    echo "===== removable-bridge start $(date --iso-8601=seconds) ====="
} >>"./fng-disks/removable-bridge.log"

./fng-disks/bin/removable-bridge "$CONTAINER_PID" /run/media/fng "$(pwd)/fng-disks/bin/mountinject" "$PROXY_DIR/removable.sock" >>"./fng-disks/removable-bridge.log" --no-automount 2>&1 &
removable_bridge_pid=$!

# check x11 display rather than treating running as ready. only best effort heuristic
plasma_desktop_ready() {
    local clients wid props
    clients=$(LC_ALL=C xprop -root _NET_CLIENT_LIST 2>/dev/null) || return 1
    for wid in $(grep -oE '0x[[:xdigit:]]+' <<< "$clients"); do
        props=$(LC_ALL=C xprop -id "$wid" WM_CLASS _NET_WM_WINDOW_TYPE 2>/dev/null) || continue
        if [[ "$props" == *plasmashell* && "$props" == *_NET_WM_WINDOW_TYPE_DESKTOP* ]] && LC_ALL=C xwininfo -id "$wid" 2>/dev/null | grep -q 'Map State: IsViewable'; then
            return 0
        fi
    done
    return 1
}

wait_for_desktop() {
    local started=$SECONDS warned=0 timeout=${FNG_SPLASH_READY_TIMEOUT:-90}
    # readiness monitor owns follower
    journal_pid=
    trap 'stop_job "$journal_pid"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    if [[ "${FNG_SPLASH_JOURNAL:-1}" != 0 && -n "$FNG_SPLASH_LOG" ]]; then
        echo "===== Container startup journal =====" >> "$FNG_SPLASH_LOG"
        timeout --kill-after=5s 185s podman exec --user 0 arch timeout --kill-after=5s 180s journalctl -b -f --no-tail --no-pager --no-hostname -o short-monotonic </dev/null >> "$FNG_SPLASH_LOG" 2>&1 &
        journal_pid=$!
    fi
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=90
    if ! command -v xprop >/dev/null || ! command -v xwininfo >/dev/null; then
        echo "Splash: xprop/xwininfo unavailable; revealing desktop without readiness detection"
        status ready "Ready" ""
        return
    fi
    status busy "Preparing desktop..."
    while kill -0 "$podman_pid" 2>/dev/null; do
        if plasma_desktop_ready; then
            echo "Splash: mapped Plasma desktop detected"
            status ready "Ready" ""
            return
        fi
        if (( !warned && SECONDS - started >= timeout )); then
            echo "Splash: no mapped Plasma desktop detected after $timeout seconds"
            status error "Plasma is taking longer than expected" "Dismiss to view the desktop."
            warned=1
        fi
        sleep 0.5
    done
}

if [[ -n "$FNG_SPLASH_STATUS" ]]; then
    wait_for_desktop &
    readiness_pid=$!
fi

wait "$podman_pid"
rc=$?
podman_pid=
exit "$rc"

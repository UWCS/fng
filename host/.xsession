#!/bin/bash
# Redirect output to a log file and to the console
exec > >(tee -i -a $USER-xsession.log) 2>&1

# Check if DISPLAY is set
if [ -z "$DISPLAY" ]
then
    echo "DISPLAY is not set. Please set DISPLAY before running this script or start an X server."
    exit 1
fi

xsetroot -solid black
xhost +local:

flatpak override --user --filesystem=./ io.mpv.Mpv

flatpak run --user io.mpv.Mpv --fs --geometry=1920x1080+0+0 --panscan=1.0 --no-border --no-osc --no-osd-bar --loop-file=inf ./GOOSE.mp4 & SPLASH=$!


# Find the distrobox binary
# Using a list loop over the possible locations
if command -v distrobox &> /dev/null
then
    distrobox=$(which distrobox)
elif [ -f ~/.local/bin/distrobox ]
then
    distrobox=~/.local/bin/distrobox
else
    echo "distrobox is not installed. Please install distrobox before running this script."
    exit 1
fi

echo "Using distrobox from \"$distrobox\""

podman kill arch
podman rm -f arch
podman unshare buildah unmount --all

(
    until podman container inspect -f '{{.State.Running}}' arch 2>/dev/null | grep -q "true"; do
        sleep 0.5
    done

    until podman exec arch pgrep -x "plasmashell" > /dev/null 2>&1; do
        sleep 0.5
    done
    sleep 2
    
    flatpak kill io.mpv.Mpv
    
    kill -9 $SPLASH 2>/dev/null
) &


mkdir -p "/var/tmp/$USER"

./local-registry.sh

image="localhost:5000/fng:dev"

podman pull --tls-verify=false $image

echo "Running in dev mode"

ulimit -n $(ulimit -Hn)

podman create \
    --hostname $(hostname) \
    --name "arch" \
    --privileged --security-opt label=disable \
    --pids-limit=-1 \
    --user root:root \
    --ipc host --network host \
    --label "manager=distrobox" --label "distrobox.unshare_groups=1" \
    --env "SHELL=bash" \
    --env "HOME=/home/fng" \
    --env "container=podman" \
    --env "CONTAINER_ID=arch" \
    --env "TZ=Europe/London" \
    --env "LANG=en_GB.UTF-8" \
    --env "HOST_LOCALE=en_GB.UTF-8" \
    --volume /tmp:/tmp:rslave \
    --volume $distrobox-init:/usr/bin/entrypoint:ro \
    --volume /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro \
    --volume /dev:/dev:rslave \
    --volume /sys:/sys:rslave \
    --volume /:/run/host/:rprivate \
    --volume /dev/pts \
    --volume /dev/null:/dev/ptmx \
    --volume /var/log/journal \
    --volume /etc/hosts:/etc/hosts:ro \
    --volume /etc/resolv.conf:/etc/resolv.conf:ro \
    --volume /etc/hostname:/etc/hostname:ro \
    --annotation run.oci.keep_original_groups=1 \
    --systemd=always --ulimit host --userns keep-id \
    --entrypoint /usr/bin/entrypoint \
    $image \
    --verbose --name $USER --user $(id -u) --group $(id -g) \
    --home "/home/fng" --init "1" --nvidia "1" \
    --pre-init-hooks "mkdir -p /usr/local/bin && chown -R $(id -u):$(id -g) /home/fng && mv /usr/bin/pacman /usr/bin/p && ln -s /usr/bin/true /usr/bin/pacman && mv /etc/pacman.conf /etc/p.conf && touch /etc/pacman.conf" \
    --additional-packages "" \
    -- "rm -f /usr/bin/pacman && mv /usr/bin/p /usr/bin/pacman && mv /etc/p.conf /etc/pacman.conf"
    ## setup_pacman more like go eat yourself

$distrobox enter arch -- echo "Started Container"
podman exec \
--interactive \
--detach-keys= \
--user=$USER \
--workdir /home/fng \
--env CONTAINER_ID=arch \
--env "SHELL=bash" \
--env DISPLAY=$DISPLAY \
arch bash -l -c "./startsession.sh; logout"

podman stop arch
podman rm -f arch
podman unshare buildah unmount --all

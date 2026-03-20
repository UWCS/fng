#!/bin/bash
# Redirect output to a log file and to the console
exec > >(tee -i -a /tmp/$USER-xsession.log) 2>&1

# Check if DISPLAY is set
if [ -z "$DISPLAY" ]
then
    echo "DISPLAY is not set. Please set DISPLAY before running this script or start an X server."
    exit 1
fi

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

mkdir -p "/var/tmp/$USER"

# if DEV variable is set run dev container
if [ -n "$DEV" ]
then
    echo "Running in dev mode"
    image="localhost/fng:dev"
else
    echo "Pulling the Latest container image"
    image="ghcr.io/uwcs/fng:latest"
    podman pull $image
fi

podman create \
    --hostname $(hostname) \
    --name "fedora" \
    --privileged --security-opt label=disable --security-opt apparmor=unconfined \
    --pids-limit=-1 \
    --user root:root \
    --ipc host --network host \
    --label "manager=distrobox" --label "distrobox.unshare_groups=1" \
    --env "SHELL=bash" \
    --env "HOME=/home/fng" \
    --env "container=podman" \
    --env "CONTAINER_ID=fedora" \
    --volume /tmp:/tmp:rslave \
    --volume $distrobox-init:/usr/bin/entrypoint:ro \
    --volume /:/run/host/:rslave \
    --volume /dev:/dev:rslave \
    --volume /sys:/sys:rslave \
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
    --pre-init-hooks "mkdir -p /usr/local/bin && chown -R $(id -u):$(id -g) /home/fng" \
    --additional-packages "" -- ''


$distrobox enter fedora -- echo "Started Container"
podman exec \
export XAUTHORITY=/home/YOUR_USERNAME/.Xauthority; \
export XDG_RUNTIME_DIR=/run/user/1000; \
export CLUTTER_BACKEND=x11; \
export QT_X11_NO_MITSHM=1

podman exec \
--interactive \
--detach-keys= \
--user=$USER \
--workdir /home/fng \
--env CONTAINER_ID=fedora \
--env "SHELL=bash" \
--env DISPLAY=$DISPLAY \
fedora bash -l -c "./startsession.sh; logout"

podman stop -it 0 fedora
podman rm -f fedora

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

echo "Stopping and removing any existing containers"
podman stop -it 0 arch
podman rm -f arch

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

# OLD:
# $distrobox create --nvidia -i $image -n arch -I --no-entry --pre-init-hooks "mkdir -p /usr/local/bin && chown -R $(id -u):$(id -g) /home/fng" -d | sed -e '\#--volume "'$HOME'":#d' -e '\#--home "'$HOME'"#c\--home "/home/fng"' -e '\#--volume /dcs:#d' | tr '\n' ' ') | source /dev/stdin

# This line is required?
XDG_RUNTIME_DIR=/run/user/$(id -u)

podman create \
    --hostname $(hostname) \
    --name "arch" \
    --privileged --security-opt label=disable --security-opt apparmor=unconfined \
    --pids-limit=-1 \
    --user root:root \
    --ipc host --network host \
    --label "manager=distrobox" --label "distrobox.unshare_groups=1" \
    --env "SHELL=bash" \
    --env "HOME=/home/fng" \
    --env "container=podman" \
    --env "CONTAINER_ID=arch" \
    --volume /tmp:/tmp:rslave \
    --volume $distroboxinit:/usr/bin/entrypoint:ro \
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

podman stop -it 0 arch
podman rm -f arch

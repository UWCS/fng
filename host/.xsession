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

# This is horrifying, and I know full well it is.
# But it works, and the systems were completely
# broken until adding this line. Therefore,
# we ball. - Tom
# nah its chill bro - alex
echo "Attempting to reset podman"
# podman system reset -f
# (I'm not responsible for anything after this line)
# me neither - alex

# if DEV variable is set run dev container
if [ -n "$DEV" ]
then
    echo "Running in dev mode"
    image="localhost/fng:dev"
else
    echo "Pulling the Latest container image"
    #image="ghcr.io/ublue-os/bazzite-arch" # blame artem tom and luna
    #image="quay.io/toolbx/ubuntu-toolbox:24.04" # please please please please please please please please please please please
    #image="ghcr.io/uwcs/fng:latest"
    image="ghcr.io/uwcs/fng@sha256:e339c4ad68dafd76436fcbd2a212f452ae29ef0117052c7d08814ef71e8ecd5c" #oopsies - luna
    podman pull $image
fi

# OLD:
#$distrobox create --nvidia -i $image -n arch -I --no-entry --pre-init-hooks "mkdir -p /usr/local/bin && chown -R $(id -u):$(id -g) /home/fng" -d | sed -e '\#--volume "'$HOME'":#d' -e '\#--home "'$HOME'"#c\--home "/home/fng"' -e '\#--volume /dcs:#d' | tr '\n' ' ') | source /dev/stdin

# commented out, i pray.

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


$distrobox enter arch -- echo "Started Container"
podman exec \
--interactive \
--detach-keys= \
--user=$USER \
--workdir /home/fng \
--env CONTAINER_ID=arch \
--env "SHELL=bash" \
--env DISPLAY=$DISPLAY \
arch bash -l -c "sudo pacman -S godot libresprite blender gimp --noconfirm; paru --noconfirm -S unityhub; ./startsession.sh; logout" # random bullshit, go - luna

podman stop -it 0 arch
podman rm -f arch

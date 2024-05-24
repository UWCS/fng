#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/tmp/$USER-xsession.log 2>&1

alias distrobox=".local/bin/distrobox"

mkdir -p "/var/tmp/$USER"

podman stop -t 0 arch
podman rm -f arch

distrobox create --nvidia -i ghcr.io/alexwright1324/fng:latest -n arch -I --no-entry -d | sed -e '\#--volume "'$HOME'":#d' -e '\#--home "'$HOME'"#c\--home "/home/fng"' -e '\#--env "HOME='$HOME'"#c\--env "HOME=/home/fng"' | tr '\n' ' ' | source /dev/stdin

podman start arch
podman exec --interactive --detach-keys="" --user='root' --workdir="/home/fng" --env "CONTAINER_ID=arch" arch chown -R $(id -u):$(id -g) /home/fng
podman exec --interactive --detach-keys="" --user=$USER --workdir="/home/fng" --env "CONTAINER_ID=arch" --env "DISPLAY=${DISPLAY}" arch dbus-run-session startplasma-x11

podman stop -t 0 arch
podman rm -f arch
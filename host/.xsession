#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/tmp/$USER-xsession.log 2>&1

distrobox=".local/bin/distrobox"

mkdir -p "/var/tmp/$USER"

podman stop -t 0 arch
podman rm -f arch

podman pull ghcr.io/alexwright1324/fng:latest

$distrobox create --nvidia -i ghcr.io/alexwright1324/fng:latest -n arch -I --no-entry --pre-init-hooks "mkdir -p /usr/local/bin && chown -R $(id -u):$(id -g) /home/fng" -d | sed -e '\#--volume "'$HOME'":#d' -e '\#--home "'$HOME'"#c\--home "/home/fng"' -e '\#--volume /dcs:#d' | tr '\n' ' ' | source /dev/stdin

podman start arch
podman exec --interactive --detach-keys="" --user=$USER --workdir="/home/fng" --env "CONTAINER_ID=arch" --env "DISPLAY=${DISPLAY}" --env "HOME=/home/fng" arch dbus-run-session startplasma-x11

podman stop -t 0 arch
podman rm -f arch

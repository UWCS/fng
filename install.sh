#!/bin/bash
set -e

# Install with
# curl -s https://raw.githubusercontent.com/UWCS/fng/main/install.sh | sh

# Download files
URL="https://raw.githubusercontent.com/UWCS/fng/main"
curl "${URL}/host/storage.conf" --create-dirs -o "${HOME}/.config/containers/storage.conf"
curl "${URL}/host/.xsession" --create-dirs -o "${HOME}/.xsession"
curl "${URL}/host/xstartup" --create-dirs -o "${HOME}/.vnc/xstartup"

# Download distrobox
# Find the distrobox binary
if command -v distrobox &> /dev/null
then
    distrobox=$(which distrobox)
elif [ -f ~/.local/bin/distrobox ]
then
    distrobox=~/.local/bin/distrobox
else
    echo "Installing distrobox"
    curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --next --prefix ~/.local
fi

echo "Installed Sucessfully"

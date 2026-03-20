FROM docker.io/library/fedora:latest AS fedora

# Initialization
RUN sudo dnf install --assumeyes @development-tools
RUN sudo dnf install --assumeyes @kde-desktop-environment
RUN sudo dnf install --assumeyes \
        # Base Tools
        wget git nano htop neovim \
        # Audio
        # pulseaudio plasma-pa kde-gtk-config pkg-config \
        # GUI Apps
        firefox flatpak lutris \
        java-21-openjdk \
        # Dependencies
	    cargo openssl
RUN wget -qO- https://astral.sh/uv/install.sh | sh
RUN sudo dnf install --assumeyes \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm -y
RUN sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

# Install DCSPkg
# RUN cargo install dcspkg --root /usr

# Create home directory
RUN mkdir -p /home/fng
WORKDIR /home/fng
COPY home ./
# Install DCSLauncher
RUN git clone https://github.com/UWCS/dcslauncher.git
# # Install FNG-Admin Client
# RUN mkdir -p fng-admin/client && cd fng-admin/client && \
#     python -m venv .venv && \
#     .venv/bin/python -m pip install https://github.com/AlexWright1324/fng-admin/releases/latest/download/client-0.1.0-py3-none-any.whl
# WORKDIR /

# Cleanup
# We do this last because it'll only apply to updates the user makes going forward. We don't want to optimize for the build host's environment.
# RUN sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf && \
#     userdel -r build && \
#     rm -drf /home/build && \
#     sed -i '/build ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
#     sed -i '/root ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
#     rm -rf \
#         /tmp/* \
#         /var/cache/pacman/pkg/*

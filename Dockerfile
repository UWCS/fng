FROM docker.io/library/archlinux:latest AS arch

# Pacman Initialization
# Create build user
RUN sed -i 's/#Color/Color/g' /etc/pacman.conf && \
    printf "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | tee -a /etc/pacman.conf && \
    sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc)"/g' /etc/makepkg.conf && \
    pacman -Syu --noconfirm && \
    pacman -S \
        wget \
        base-devel \
        git \
        --noconfirm && \
    useradd -m --shell=/bin/bash build && usermod -L build && \
    echo "build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

RUN pacman -Syu \
        nano fuse3 \
        xorg-server vulkan-tools plasma-desktop xdg-desktop-portal-kde \
        pulseaudio plasma-pa kde-gtk-config pkg-config \
        firefox konsole dolphin \
        flatpak \
        steam lutris \
	cargo \
        --noconfirm

# Install DCSPkg
RUN cargo install dcspkg --root /usr

# Add Flathub
RUN flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Add paru and install AUR packages
USER build
WORKDIR /home/build
RUN git clone https://aur.archlinux.org/paru-bin.git --single-branch && \
    cd paru-bin && \
    makepkg -si --noconfirm && \
    cd .. && \
    rm -drf paru-bin
RUN paru --noconfirm -S prismlauncher-qt5-bin jre17-openjdk jre21-openjdk
USER root
WORKDIR /

# Create home directory
RUN mkdir -p /home/fng
WORKDIR /home/fng
COPY home ./
RUN git clone https://github.com/UWCS/dcslauncher.git
WORKDIR /

# Cleanup
# We do this last because it'll only apply to updates the user makes going forward. We don't want to optimize for the build host's environment.
RUN sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf && \
    userdel -r build && \
    rm -drf /home/build && \
    sed -i '/build ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    sed -i '/root ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers && \
    rm -rf \
        /tmp/* \
        /var/cache/pacman/pkg/*

FROM docker.io/library/archlinux:latest AS arch

# Initialization
RUN sed -i 's/#Color/Color/g' /etc/pacman.conf && \
    printf "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" | tee -a /etc/pacman.conf && \
    sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc)"/g' /etc/makepkg.conf && \
    pacman -Syu \
        # Base Tools
        base-devel wget git nano htop \
        # Desktop Environment
        xorg-server plasma-desktop xdg-desktop-portal-kde vulkan-tools fuse3 kwin-x11 \
        # Audio
        pulseaudio plasma-pa kde-gtk-config pkg-config \
        # GUI Apps
        firefox discover konsole dolphin kate \
        flatpak steam lutris \
        prismlauncher jre17-openjdk jre21-openjdk \
        godot libresprite blender gimp \
        # Dependencies
	    cargo rye \
        --noconfirm && \
    useradd -m --shell=/bin/bash build && usermod -L build && \
    echo "build ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Install DCSPkg
RUN cargo install dcspkg --root /usr

# Add paru and install AUR packages
USER build
WORKDIR /home/build
RUN git clone https://aur.archlinux.org/paru-bin.git --single-branch && \
    cd paru-bin && \
    makepkg -si --noconfirm && \
    cd .. && \
    rm -drf paru-bin
RUN paru --noconfirm -S unityhub
USER root
WORKDIR /

# Create home directory
RUN mkdir -p /home/fng
WORKDIR /home/fng
COPY home ./
# Install DCSLauncher
RUN git clone https://github.com/UWCS/dcslauncher.git
# Install FNG-Admin Client
RUN mkdir -p fng-admin/client && cd fng-admin/client && \
    python -m venv .venv && \
    .venv/bin/python -m pip install https://github.com/AlexWright1324/fng-admin/releases/latest/download/client-0.1.0-py3-none-any.whl
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

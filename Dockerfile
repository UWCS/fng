FROM docker.io/cachyos/cachyos-v3:latest AS arch

COPY ./home/pacman.conf /etc/pacman.conf

RUN pacman-key --init && \
    pacman-key --populate archlinux

RUN pacman -Sy --noconfirm \
    cachyos-keyring \
    cachyos-mirrorlist

RUN sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc)"/g' /etc/makepkg.conf && \
    pacman -Syu --noconfirm \
        base-devel wget git nano htop \
        xorg-server plasma-desktop xdg-desktop-portal-kde fuse3 vulkan-tools kwin-x11 \
        pulseaudio plasma-pa kde-gtk-config \
        firefox discover konsole dolphin kate \
        flatpak steam lutris yay \
        prismlauncher jre21-openjdk proton-cachyos && \
    pacman -S --noconfirm rust && \
        cargo install dcspkg --root /usr && \
        pacman -Rns --noconfirm rust && \
    rm -rf \
        ~/.cache/yay/* \
        /tmp/* /var/cache/pacman/* \
        /var/lib/pacman/sync/* \
        /root/.cargo \
        /usr/share/man/* \
        /usr/share/doc/* \
        /usr/share/gtk-doc/* && \
    echo "ALL ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/acc && \
    	chmod 0440 /etc/sudoers.d/acc

RUN mkdir -p /home/fng
WORKDIR /home/fng
COPY home ./
RUN git clone --depth=1 https://github.com/UWCS/dcslauncher.git

RUN sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf

# pull x86_64-v3 cachy variant. w/ avx512 support on a test machine, can be swapped to v4. target doesn't have avx512
FROM docker.io/cachyos/cachyos-v3:latest AS arch

# has e.g. NoExtract directive. dirs get nuked later down anyway to reduce image size but should mildly reduce build time
# make sure root in container owns it
COPY --chown=0:0 ./home/pacman.conf /etc/pacman.conf

# make sure pacman can check against cachy signed packages
# arch as failsafe in case someone wanting to install non-cachy-recompiled packages
# target machines are x86_64-v3 so use v3 mirrorlist
# yeet rust after dcspkg build to reduce final image size (ideally sort dcspkg ci out soon though)
RUN pacman-key --init && \
    pacman-key --populate \
        archlinux cachyos && \
    pacman -Sy --noconfirm \
        cachyos-keyring \
        cachyos-v3-mirrorlist && \
    pacman -Syu --noconfirm \
        base-devel wget git nano htop \
        plasma-desktop xdg-desktop-portal-kde vulkan-tools kwin-x11 \
        pipewire pipewire-pulse pipewire-alsa plasma-pa kde-gtk-config \
        firefox discover konsole dolphin kate \
        flatpak steam lutris \
        prismlauncher jre21-openjdk && \
    pacman -S --noconfirm rust && \
        cargo install dcspkg --root /usr && \
        pacman -Rns --noconfirm rust

# clear out dirs with redundant files
# do locale gen (US too since e.g. steam & others will look for it and generate them anyway if not present)
# optimise pkg build if e.g. user uses aur/yay to build against architecture of host (useful if building image non-locally)
RUN rm -rf \
        /tmp/* /var/cache/pacman/* \
        /var/lib/pacman/sync/* \
        /root/.cargo \
        /usr/share/man/* \
        /usr/share/doc/* \
        /usr/share/gtk-doc/* && \
    sed -i 's/#en_GB.UTF-8/en_GB.UTF-8/g' /etc/locale.gen && \
    sed -i 's/#en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen && \
        locale-gen && \
    sed -i 's/-march=x86-64 -mtune=generic/-march=native -mtune=native/g' /etc/makepkg.conf

# add fng user and make it a passwordless sudoer, and create run dirs
# sudo will ignore if not 0440
# enable linger to get user systemd at startup
# mask services that won't work in the container anyway or that are redundant since what they do is handled by the host
RUN useradd -u 1000 -m -s /bin/bash fng && \
        echo "fng ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/fng && \
        chmod 0440 /etc/sudoers.d/fng && \
        mkdir -p /var/lib/systemd/linger && \
        touch /var/lib/systemd/linger/fng && \
        systemctl mask \
            getty@.service console-getty.service polkit.service \
            proc-sys-fs-binfmt_misc.automount systemd-remount-fs.service systemd-udevd.service \
            systemd-udev-trigger.service initrd-udevadm-cleanup-db.service systemd-firstboot.service \
            systemd-update-utmp.service systemd-tmpfiles-clean.service \
            systemd-network-generator.service systemd-network-persistent-storage.service \
            systemd-networkd.service systemd-networkd-wait-online.service \
            systemd-resolved.service systemd-resolved-monitor.socket systemd-resolved-varlink.socket \
            systemd-networkd-resolve-hook.socket systemd-networkd-varlink-metrics.socket \
            systemd-networkd-varlink.socket systemd-networkd.socket systemd-nsresourced.service \
            systemd-nsresourced.socket systemd-machine-id-commit.service

# copy pre-config'd home dir and make our user the owner of it
USER fng
WORKDIR /home/fng
COPY --chown=1000:1000 home ./
RUN mkdir -p ./.config/systemd/user/default.target.wants && \
    ln -s ./.config/systemd/user/startsession.service ./.config/systemd/user/default.target.wants/startsession.service && \
    flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# ideally sort ci out for this as well
RUN git clone --depth=1 https://github.com/UWCS/dcslauncher.git

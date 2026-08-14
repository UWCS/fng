# pull x86_64-v3 cachy variant. w/ avx512 support on a test machine, can be swapped to v4. target doesn't have avx512
FROM docker.io/cachyos/cachyos-v3:latest AS arch

# has e.g. NoExtract directive. dirs get nuked later down anyway to reduce image size but should mildly reduce build time
# make sure root in container owns it
COPY --chown=root:root ./home/pacman.conf /etc/pacman.conf

# make sure pacman can check against cachy signed packages
# arch as failsafe in case someone wanting to install non-cachy-recompiled packages
# target machines are x86_64-v3 so use v3 mirrorlist
# yeet rust after dcspkg build to reduce final image size (ideally sort dcspkg ci out soon though)
# default ocl-icd is missing symbols, opencl-icd-loader fixes this
    # available in cachy repos, aur on vanilla arch
    # --ask=4 corresponds to ALPM_QUESTION_CONFLICT_PKG i.e. answer Y not N to opencl-icd-loader replacing ocl-icd
RUN pacman-key --init && \
    pacman-key --populate \
        archlinux cachyos && \
    pacman -Syu --noconfirm \
        base-devel wget git less nano htop noto-fonts-cjk \
        plasma-desktop xdg-desktop-portal-kde vulkan-tools kwin-x11 \
        pipewire pipewire-pulse pipewire-alsa plasma-pa kde-gtk-config \
        firefox discover konsole dolphin kate \
        flatpak steam lutris spectacle \
        prismlauncher jre21-openjdk && \
    pacman -S --ask=4 opencl-icd-loader && \
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

# add fng user and make it a passwordless sudoer
# sudo will ignore if not 0440
# mask services that won't work in the container anyway or that are redundant since what they do is handled by the host
RUN useradd -u 1000 -m -s /bin/bash fng && \
        echo "fng ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/fng && \
        chmod 0440 /etc/sudoers.d/fng && \
        systemctl mask \
            getty@.service console-getty.service \
            proc-sys-fs-binfmt_misc.automount systemd-remount-fs.service systemd-udevd.service \
            systemd-udev-trigger.service initrd-udevadm-cleanup-db.service systemd-firstboot.service \
            systemd-update-utmp.service systemd-tmpfiles-clean.service \
            systemd-tmpfiles-setup-dev-early.service systemd-tmpfiles-setup-dev.service \
            systemd-tmpfiles-setup.service systemd-tmpfiles-clean.timer \
            systemd-network-generator.service systemd-network-persistent-storage.service \
            systemd-networkd.service systemd-networkd-wait-online.service \
            systemd-resolved.service systemd-resolved-monitor.socket systemd-resolved-varlink.socket \
            systemd-networkd-resolve-hook.socket systemd-networkd-varlink-metrics.socket \
            systemd-networkd-varlink.socket systemd-networkd.socket systemd-nsresourced.service \
            systemd-nsresourced.socket systemd-machine-id-commit.service \
            polkit-agent-helper.socket && \
        chmod u+s /usr/lib/polkit-1/polkit-agent-helper-1

# copy default polkit auto-allow rules. note for kernel <6.12 suid agent must be used
COPY --chown=root:polkitd --chmod=0640 host/99-fng-polkit.rules /etc/polkit-1/rules.d/99-fng-polkit.rules

# copy systemd service that will handle login
COPY --chown=root:root --chmod=0644 host/startsession.service /etc/systemd/system/startsession.service
RUN systemctl enable startsession.service

# copy pre-config'd home dir and make our user the owner of it
USER fng
WORKDIR /home/fng
COPY --chown=fng:fng home ./
RUN flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# ideally sort ci out for this as well
RUN git clone --depth=1 https://github.com/UWCS/dcslauncher.git

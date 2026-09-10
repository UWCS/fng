# Friday Night Gaming Container (aka "The FNG Account")

An isolated Podman container running CachyOS for running games on the CS0.03 PCs via our shared account for Friday Night Gaming.

> Project currently maintained primarily by @raven0034

*Note: User data e.g. logins, downloads, game save data etc, from usage of the container do not get stored post-logout, and is designed to be as isolated as reasonably possible from the host.*

You can set this up yourself for usage on your own account/machine - see the #environment section for more detailed technical information.

## Usage
- Clone or download this repository
- Create `.xsession` in the root of your home folder. If you've got the repo set up at `~/fng`, `.xsession` should be:
```sh
#!/bin/bash

cd fng
host/.xsession
```
- Copy `host/storage.conf` to `~/.config/containers/storage.conf`
    - *If experiencing issues in the next step (esp if moving from fuse to overlayfs), advised to run `podman system reset -f` post-copy, which will remove all current containers, images and volumes, and apply the storage configuration*
- Run `builddev.sh` - this will take a few minutes, and will produce a `fng-dev.tar.zst` (approx 1.5GB)
- Logout and on the login screen, enter your username, and on the password/2FA page, click the cog and select "User Script"
    - *This is remembered per machine, and you'll need to change it back e.g. to "Plasma (X11)" to login normally*

## Basics of how it works
- `host/.xsession` - Main script which handles copying & decompressing the up-to-date container image into local storage, and setting up the container
- `host/storage.conf` --> `~/.config/containers/storage.conf` - Configuration for temporary `overlayfs` storage on the local disk when running the container where game installations etc will go, and where the container images are built to
- `host/cdi.yaml` - Generated configuration by the NVidia Container Toolkit to specify mounts for GPU passthrough
- `host/startsession.service` - `systemd` service for login flow and starting Plasma KDE
- `home/` - Barebones home folder for the `fng` user in the container, with some default Plasma KDE configuration
- `rundev.sh` - Script for running container via a windowed X Server using Xephyr (only for development)

## Environment
- Software Packages (already installed in DCS):
    - `podman` (tested with 5.8.2)
    - `skopeo` (tested with 1.22.2)
    - `nvidia-ctk` (tested with 1.13.5 & CDI spec 0.5\*)
    - `zstd` (tested with 1.5.5)

- System
    *Note: inherently non-exhaustive since there's a myriad of reasons things could break depending on system setup.*
    - User namespaces enabled
        - `cat /proc/sys/user/max_user_namespaces` --> non-zero (recommended minimum 1000)
    - Unrestrict unprivileged user namespaces
        - `cat /proc/sys/kernel/unprivileged_userns_clone` --> 1
            - Debian-specific, control not present on Rocky. `bwrap` fails if not enabled, breaking Steam, Flatpak and much more
        - `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` --> 0 & `cat /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined` --> 0 
            - *or* make a targeted AppArmor profile for the container (good luck lol)
    - CGroup namespaces enabled
        - `cat /proc/sys/user/max_cgroup_namespaces` --> non-zero (recommended min 100)
    - IPC namespaces enabled
    - Mount namespaces enabled
    - PID namespaces enabled
    - UTS namespaces (not strictly required but implied by setting hostname)
    - Unprivileged `strace` enabled
        - cat `/proc/sys/kernel/yama/ptrace_scope` --> 1 or 0
            - The container *can* function somewhat fine with `ptrace_scope` of 2 but various issues e.g. with Sober, Ubisoft Connect and anticheats generally are much more predominant. *Not recommended nor supported*
    - `rw` access to `/dev/fuse`
    - `CAP_SYS_ADMIN` capabilities able to be granted to the container
    - X11 - Wayland is not currently supported
        - Nesting X11 in Wayland is fine though
    - Permissive SELinux for the container
        - You can check the overall SELinux status with `sestatus`
        - Currently disabled in DCS - not recommended to fully disable if on a personal machine
    - Non-restrictive `seccomp` - not an issue in DCS, but if enabled, various syscalls get blocked by default which can cause issues with `unshare`, `bwrap` etc.
    - `udev` rules such as `steam-input.rules` to enable controller usage

## Extra Technical Details & Useful Resources
> This took a long time to get working, and there's quite a lot I read about, experimented with etc, in the process. Starting understanding the technical requirements more deeply when kernel exploits started raining out the sky a while back has proven to be invaluable, and quite interesting.
> So here goes nothing, hopefully this saves some pain in the future.

> *Will likely update various parts as I (re-)remember/discover things - some of it is buried in the depths of my search history*

### Firstly, and most importantly, why use a (rootless) container? Can't we just run things natively via the host OS?
The DCS PCs (currently) run [Rocky Linux](https://rockylinux.org/), which *can* run various things natively (the solution prior to this project's existence).

However, a combination of Rocky being a pain (enterprise distro not being geared around gaming etc), a lack of elevated access, and various other issues, can make this a pain very quickly, depending on what it is being run. It's worth checking out the [DCS System User Guide](https://warwick.ac.uk/fac/sci/dcs/intranet/user_guide/) if you're looking for current guidance on running specific games/other software.

(sidenote: you can have some limited success running things natively via [`steamcmd`](https://developer.valvesoftware.com/wiki/SteamCMD) if issues with namespaces/similar, but license checking can be a stumbling block where the Steam client itself is unable to run - this can be worked around with some tools for some games e.g. Terraria however this is a legal grey area and I wouldn't recommend it (deliberate vague). If you own something like BeamNG through Steam, you can download and play this fine since it doesn't have licensing checks)

Rootless containers (unsurprisingly) run without root, which reduces attack surface if there's security issues within a given container. It also means that they can run entirely unprivileged; with the usage of user namespaces (detailed below), this allows the running of a kiosk-like setup, where an OS which can be modified etc inside the container, with system processes believing they are root - they are instead "fake root", and cannot (legitimately) exceed the capabilities over the host machine that the host account running the container would have.

This setup *allows* for far more flexibility, and containerisation makes it far easier to keep people's data safe - imperative since this is hosted via our shared DCS account. Beyond issues e.g. tied to rolling distributions (detailed below), using a container, created fresh at the point of login, and destroyed at logout, enables reproducibility - if one person breaks something in their instance of the container, it has no impact on the others.

The DCS PCs use Podman rather than Docker. Podman is preferred regardless given its performance over Docker (and convenience of use).

### Userscript & xsession
Currently, the DCS PCs use [`gdm`](https://wiki.archlinux.org/title/GDM) as their login manager. One of the configured options is `Userscript`, which allows the execution of commands scripted in e.g. `~/.xsession`, within & controlling an [X11](https://wiki.archlinux.org/title/Xorg) (graphics system that controls X windows - ie what you see on the display) session.

The DCS PCs do *not* have Wayland (what is beginning to more widely replace X11) enabled (see below). This is particularly noteworthy as the container uses Plasma KDE as its desktop environment, which [drops X11 compatibility entirely when 6.8 releases](https://blog.davidedmundson.co.uk/blog/596/) (in Oct).

### Debugging (e.g. via tty)
Ctrl+Alt+F1 through F5 allows you to switch sessions. If a live instance of the container breaks, this can be useful, since you can drop into a tty on the host, and use e.g. `podman exec -it arch bash` to get a shell in the container.

If debugging in a non-root context, `systemctl` can still often be used via specifying `--machine=fng@.host` alongside `--user`. It's also worth checking `journalctl` as an early port of call, since this often reveals the issue - however, take caution since many warnings are noise.

If experimenting around with packages on the host, DCS has a synced copy of the Rocky repos (on `/dcs/yum`) that you can obtain RPMs for. Then you can use `rpm2cpio some_pkg_name.rpm | cpio -idmv` to effectively extract and run the package barebones.

For general debugging/learning purposes, I would strongly recommend both the Arch Wiki (general Linux shenanigans) and Red Hat's articles (very useful for insight into containers, security and more).

### Operating System
This project used to use Arch Linux, and currently uses a variant called CachyOS (specifically the x86_64-v3 variant - [interesting gist here](https://gist.github.com/FCLC/56e4b3f4a4d98cfd274d1430fabb9458) about why no AVX-512 on Alder Lake CPUs, hence no v4 support), which supplies packages and a kernel with further CPU optimisations. It retains the same functionality found in Arch Linux, and is also a rolling distribution. Rolling distributions do come with some risk to reproducibility, if something breaks, it is strongly recommended to try a previous build, re-build the project or similar, particularly if no changes have been made in this repo. The `System` section outlines system requirements that should also be checked.
*Note: You can also retrieve older package versions e.g. from the Arch Linux archive. This may come in handy e.g. for pinning Plasma to 6.7.x, since 6.8+ will drop X11 support, and the DCS PCs do not currently have Wayland enabled. With this said, see the `pacman` section about partial upgrades, since this may be difficult.*

CachyOS also has [`proton-cachyos`](https://github.com/CachyOS/proton-cachyos), a fork of Proton (emulation tool for running Windows applications, based off Wine and maintained by Valve) with additional optimisations (and has support e.g. for FSR4) and fixes based on top of the bleeding edge branch of Proton, and which can be used outside of just Steam. If installed, Steam may default to it as its "compatibility tool" (may require restart of Steam if freshly installed).
- There's quite a bit regarding debugging via Proton, however, something to revisit later. If a game is struggling to run/crashes frequently, check [ProtonDB](https://www.protondb.com/), since this will usually tell you which Proton versions (and any run flags) people have successfully gotten games working on. Over 1k games are indexed on [areweanticheatyet.com](https://areweanticheatyet.com/) if anticheat may be an issue - some games will not be feasible to run (legally) because of (kernel-level) anticheat, and are not worth wasting time on.
- [This guide](https://openplanet.dev/docs/help/linux) on installing the Openplanet extension platform for Trackmania on Linux is a nice basic example of some more advanced things you can do & debug involving Proton. You can also have a look at how Lutris install scripts (when they aren't broken lmao) for various games work to get an idea of more advanced tricks, allowing stuff like GTA V to work if you manage to win the battle against Rockstar and them causing their launcher to break on Linux every so often.
- There's other flavours of Proton/Wine like GE-Proton which circumvents codec licensing issues, and other launchers, e.g. [`umu-launcher`](https://github.com/Open-Wine-Components/umu-launcher) is a unified games launcher which `proton-cachyos` goes hand-in-hand with - for `umu` GUIs you can use e.g. [Lutris](https://github.com/lutris/lutris), or [Heroic Games Launcher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) (nicer UI imo).

The container is dependent on the host kernel, which allows various things, most important of which is GPU passthrough. Therefore kernel optimisations present in the distro used by the container will not yield the same behaviour or performance deltas compared to a standalone installation.

Arch and its variants have the [Arch User Repository (AUR)](https://aur.archlinux.org/), which has many community-built packages. However, use this with caution, as there are less assurances on the integrity of AUR packages - there have been various issues with bad actors inserting malware into packages, however this seems to have been largely cleaned up as of 10/08/26 with extra lockdowns in place. Out of an abundance of caution, `paru`, `yay` etc are not included in the build by default.

### Why not Distrobox?
The new approach to the container architecture sees a move away from [Distrobox](https://github.com/89luca89/distrobox/), which can be a useful tool for quick host integration in development environments, but is not suitable for our use case. The architecture now focuses on minimal binding from the host, with everything else isolated to the container, include `systemd` and `dbus` instances - *there is not a need to bind them from the host as long as the prerequisite work has been done, and doing so very quickly harms maintenance of any isolation approaches.*

Since Distrobox aims to "integrate with the host as tightly as possible", escaping to the host is trivial. This is an undesirable trait in the scope of our shared DCS account, since it can allow tampering of services and configuration we have created, and presents a larger attack surface on the wider DCS infrastructure. This has been a shared concern of RL & the department, and the new architecture keeps host exposure to an absolute minimum to mitigate this.

*Note: There is not evidence of tampering having occurred. However, particularly with an evolving threat landscape, moving to a more isolated architecture is the responsible mitigation.*

In its bid to cover all corners of host integration, Distrobox exhibits other undesirable behaviour, causing things like [this monstrosity](https://github.com/UWCS/fng/blob/eff27df586c40c471113a0620e37a3ed4cfd7f80/host/.xsession#L102) to work around `distrobox-init` attempting to [forcibly install a hardcoded list of packages](https://github.com/89luca89/distrobox/blob/353bc410b95e5b46251b8b2273fbf291f8f520c2/distrobox-init#L1358) - this caused a conflict between `mesa-git` and `mesa` when first migrating to Cachy. `distrobox-init` (at least, pre-Go rewrite which I haven't tried) takes upwards of 10 seconds to run on the PCs in CS0.03 - the vast majority of what it does is unnecessary.

It is still a useful resource for specific issues with host integration.

### Image distribution
The image can be built using `builddev.sh`, which builds the image to `/var/tmp` (cannot build directly to the shared account's storage due to DCS' current usage of NFSv3 it lacking xattr support), compressing to `fng-dev.tar.zst` in the same directory as the script.

`zstd` is used for compression since `gzip`, Podman's default, is woefully ineffective in both compression ratios and decompression speed, whereas `zstd` can bring the size of the built image down by around 70%, and has almost uniform decompression speeds. Good compression ratio and decompression speeds are needed to minimise the network bottleneck - in `.xsession` the image is copied from the NFS to a target machine's `/var/tmp` (ie local), which is limited to 1Gbps. Previously, the target machines individually pulled the latest image from GHCR at every login, causing login times to take up to 5 minutes.

Image copying is done using a CLI tool called [Skopeo](https://github.com/podman-container-tools/skopeo). Using this tool yields much faster copy times than doing via Podman itself.

The current approach was implemented after using a local registry. This approach was effective but introduced some unnecessary overhead, keeping login times at 30-60 seconds. Comparatively, if the image needs to be pulled onto a target machine, the login time is around 25 seconds, and if an up-to-date image is already present, the time is down to around 5 seconds!

If experimenting with a local registry, they are `http` by default - pass `--tls-verify=false` when working with `podman pull` and `podman push`.

### Pacman
`pacman` is Arch's (and Cachy's) default package manager and the go-to to install applications.

Differences with CachyOS:
- `pacman` needs to have the Cachy keyring and repositories synced to be able to install Cachy packages. This is done via `pacman-key --init && pacman-key --populate cachyos`
- Arch Linux has [its repositories](https://archlinux.org/packages/) `core` and `extra`. Packages can be installed from these repositories still with Cachy, but it additionally [includes](https://packages.cachyos.org/) (and prioritises) `cachyos-v3`, `cachyos-core-v3` and `cachyos-extra-v3` (or equivalents for other x86_64 versions), as well as the base `cachyos` repository.

Basic commands:
- `pacman -S pkg1 pkg2 ...` - install single package or list of packages, along with *required* dependencies.
- `pacman -Syu [pkg1 pkg2]` - sync repository database (i.e. remote containing package info - versions, dependencies etc) and update all packages on the system (that are in the configured repositories), as well as installing listed packages.
- `pacman -Sy` - avoid using this. This syncs the repository database *only*. This effectively runs the risk of weird mismatches where package A is present, but installing package B is dependent on the latest A; `pacman` "sees" the dependency as satisfied despite A potentially being the wrong version, leading to broken packages. This is known as a "partial upgrade".
- `pacman -R pkg` - remove single package, without uninstalling dependencies.
- `pacman -Rs pkg` - remove single package and its dependencies, if not required by any other installed package.
- `pacman -Rns pkg` - remove package, dependencies no longer required, and `pacman`-created configuration files for the package.

There are some issues of interest around dependencies:
- `conflicts` vs `replaces`: `conflicts` will prevent installation of package B if conflicting with package A, unless `replaces` is present, which substitutes a package name for a new one.
- `--noconfirm` will select the default answer, which is not always `Y`. For example, we need `opencl-icd-loader` to replace `ocl-icd` (latter is missing various symbols), the default on removing `ocl-icd` is `N`. This can be worked around using `yes |`, or using `--ask=4` which corresponds to [`ALPM_QUESTION_CONFLICT_PKG`](https://gitlab.archlinux.org/pacman/pacman/-/blob/bdedf621efc0950c6dc17525b2e4b43118e60625/lib/libalpm/alpm.h#L981) and answers `Y` by default. Take care to only do this with specific packages as needed.
- Some NVidia packages can be difficult to install via `pacman` - e.g. `nvidia-settings` "requires" the latest bleeding edge NVidia drivers - these cannot be installed since these drivers are managed by the host, and bind mounted into the container per the ICD specification generated by NVidia container toolkit.

A custom `pacman.conf` exists to avoid extraction of man pages, docs etc, to decrease image size.
- `NoExtract` is applied to the following directories in `/usr/share/` - `man/`, `doc/`, `gtk-doc/`, `help/`
- The `multilib` repositores exist to allow running 32-bit executables. CachyOS enables these repositories by default in `pacman.conf`, Arch Linux does not but can by the same lines:
```
[multilib]
Include = /etc/pacman.d/mirrorlist
```

Note: `makepkg` is a tool for automating building of packages e.g. into a tarball.

### Mapping UIDs and GIDs
In the container, `root` has UID:GID 0:0, and `fng` has 1000:1000, as typically expected. The latter is mapped to the unprivileged UID of the host account running the container (i.e. UID of DCS account). `--group-add keep-groups` maps the groups of the host user into the container, allowing preservation of ACLs applied to specific groups. These groups are not *created* within the container though and (similar as with unmapped host UIDs), they will show as `nobody` (65534) - this is nothing to be concerned about. The rest of the UIDs and GIDs in the container are mapped to a block of "sub" UIDs and GIDs on the host, usually defined in `/etc/subuid` and `/etc/subgid`.

### Namespaces
The container will not function without user namespaces (i.e. if DCS disable them again in the future because of a repeat of what happened with the CopyFail, DirtyFrag, Fragnesia etc exploit rain then don't burn your time on this!), and it is recommended that `max_user_namespaces` is set to at least 1000, since `steam`, `flatpak` etc will often refuse/otherwise fail to launch. Namespaces are a kernel feature that effectively makes a container see itself as an independent system by segmentation of resources - user namespaces giving "fake root" in the container, mount namespaces giving filesystem isolation (outside of what is explicitly bound), PID namespaces giving process isolation (important for isolation as a whole), IPC namespaces giving things like shared memory isolation.

### cgroups
Podman utilises cgroups v2, isolating resource usage for a collection of processes - helpful e.g. to stop memory leaks causing issues on the host, since the processes have to exist within the cgroup limits.

### Capabilities & SUID
[Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html) break privileges down into more granular permissions - worth noting that any permissions granted to the container via `--cap-add` exist only within the container space, and rootless containers *cannot* exceed the capabilities held by the host user. However, an approach of least privileges is best practice where possible to reduce potential attack surface, especially in the context of our DCS shared account - the most notable is the `SYS_ADMIN` capability being need for fuse to work (still need for portal mounts). Similarly, it's still worth taking caution with SUID (a permissions bit that executes a given executable as the owner user/group depending where it's set), although by default, rootless containers are usually ran without the ability to gain new privileges.

### strace
Used for inspecting other processes via the `ptrace` system call. Proton, anti-cheat etc, tend to inject into/monitor their child processes. This requires `ptrace_scope` of 1 (restrictive) which allows processes to trace their direct descendants (`ptrace_scope` of 2 effectively make it root-only).

### Storage - overlay vs fuse
Issues with overmount - occasionally there's a NVidia mount on `/proc/driver/nvidia`, at least on my personal machine (doesn't affect DCS PCs). Resolved by unmounting. Breaks `bwrap` if it remains mounted, since a `tmpfs` gets mounted over a `procfs` in this scenario, creating a polluted mount tree, preventing `bwrap` from mounting a fresh `procfs` when invoked.

The container now uses kernel native `overlayfs` rather than userspace `fuse-overlayfs` which is significantly quicker due to less overhead, and less error-prone where it comes to mount flags etc. However, when using `podman run --rm`, `disable-volatile=true` needs to be present in `storage.conf` to prevent the default behaviour of `--rm` - applying the `volatile` mount flag to the container's filesystem breaks e.g. `fsync` and subsequently breaks more complex applications like [Sober](https://flathub.org/en/apps/org.vinegarhq.Sober) (useful tester for large changes as it requires nested user namespaces, `strace` and various other bits, since it's effectively an Android emu inside an emulated GNOME env inside a Flatpak inside a container inside a user namespaces (dw I'm screaming too)). Access to `/dev/fuse` is still needed for `portal` mounts and `flatpak` to work (as well as various other sandboxed apps), to allow safe data projection back to the "host" (the container in this context).

### udev, input and ACLs (primarily wrt controllers)
`/etc/udev/60-dcs-steam-input.rules` is used as a set of udev rules, applying access control lists (ACLs) and permissions to input devices recognised by the kernel. However, out-of-date (ask DCS Tech). Also doesn't cover stuff like some XBox controllers etc - primarily covers controllers that can be handed off to `usbhid` (some need different drivers e.g. [`xpad`](https://github.com/paroj/xpad) used to be a viable option for XBox controllers. However, we can only install userspace drivers within the container. Speak to DCS Tech if you want a driver installing on the host - with Rocky being an enterprise distro that doesn't ship most of these drivers, they're less likely to say yes since they'll (probably) need to be done via DKMS).

Depending on the device, input *could* be read (if sufficient permissions), from `/dev/hidraw*`, `/dev/js*` or `/dev/input/event*`. If you e.g. run `ls` in these locations, generally seeing a `+` at the end of the file permissions gives you confirmation, but you can also check the specific access controls using `getfacl <path>`.

If you want a friendly way of testing a controller, head to [Gamepad Tester](https://hardwaretester.com/gamepad).

### Why doesn't removable storage work?
User namespaces are limited in what they can mount themselves, depending on if the target filesystem has `FS_USERNS_MOUNT` (fuse & [overlay do](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/overlayfs/super.c#n1571), ntfs, exfat, ext4 and most others do not). If not, mount events do not get passed through from the host post-startup of the container. This may be able to be bypassed with a host helper alongside the container using [`udisksctl`](https://man.archlinux.org/man/udisksctl.1.en) and e.g. fuse to get around this. If mounting e.g. a USB via `udisksctl` *before* starting the container, said USB will be accessible via `/run/media/$USER` (which can be bind-mounted into the container) until unmounted.

### Why doesn't lockscreen (currently) work?
I'm working on it! This wasn't previously possible under the Distrobox-based solution due to conflicts with the host. However, it is possible with the isolated approach.

The disabling of the lockscreen via KDE Actions is still in place in `kdeglobals` - removing this is fine, but means currently PAM needs to be configured to handle the container account being passwordless (use tty to temporarily set a password if unable to unlock without a password set). [`polkit`](https://wiki.archlinux.org/title/Polkit) is already configured to work around this - simpler than removing it given the number of packages that depend on it (and given that it's authenticating against accounts within the container now rather than on the host).

### Wayland shenanigans
DCS currently has `nomodeset` which prevents Wayland being used, since it requires Kernel Mode Setting. Without KMS enabled, X11 is used as the fallback. Rocky 10 will be Wayland only, but DCS is still (and will, for the time being) using Rocky 9.

There's various interesting things you can do with nested compositors and a myriad of other weird and wonderful things. However, I will write about those at another time when I'm less sleepy.

Main thing of note is mentioned above: Plasma 6.8 will be Wayland-only, potential upcoming issue for the project.

### NVidia Container Toolkit
This is used to generate a CDI spec in YAML, defining mountpoints for drivers, applications and libraries based on the host's hardware (in the case of the DCS PCs, they have RTX 3060s) - this is much cleaner the internals of Distrobox. Currently, `nvidia-ctk` is stuck on version 1.13.5 from 2023, which generates up to (and incl.) CDI spec v0.5. The repo structures migrated after this version, and DCS have very recently pulled the new repos down, but have not yet deployed them. The old version of `nvidia-ctk` has some issues in rootless containers e.g. with `chmod` hooks of graphics devices on `/dev` owned by root (fixed in 1.18), hence the hack around this. There's also a bug that exists even within 1.19 (current version as of writing), where the NVidia OpenCL ICD is not bind-mounted to the container, breaking OpenCL - this should be fixed for v1.20.

### Monitor goofiness with brightness & `ddcutil`
Possibly partially an upstream issue in Plasma 6, but I *think* the DCS monitors are not entirely MCCS-compliant - if I-Colour is configured to anything but "Off", the brightness cannot be changed. Attempting to change it via the applet provided by KDE Powerdevil crashes the applet rather than the previous behaviour of just (as "expected"), being ineffective (comes back on Powerdevil restart). The monitors also seem to falsely report this & various other features as available when they're not, resulting in interesting errors and garbage values.

Other random notes after experimenting on DCS monitors with [`ddcutil`](https://man.archlinux.org/man/extra/ddcutil/ddcutil.1.en):
- `ddcutil setvcp 0xd6 0x05` turns the display off; replace `0x05` with `0x01` to turn it back on again.
- Display input can be changed via `0x60` e.g. `ddcutil setvcp 0x60 0x0f` will set DisplayPort. (`0x11` instead of `0x0f` sets HDMI).
- Writing to `0x08` is *supposed* to reset the colour settings (it doesn't), only writing to `0x04` has any effect, which resets the monitor entirely.

(i.e. if you run into this issue just manually turn I-Colour off on the monitor because there doesn't seem to be a clean way to do this programatically lmao)

### (Assorted) RESOURCES (WOO!)
> Also non-exhaustive.

- [ArchWiki (& man pages)](https://wiki.archlinux.org/) - low-key the Linux bible. If there's some concept/issue you're stuck on, *very* good chance it has an answer (or links to one). Some that came in handy for me:
    - [XOrg](https://wiki.archlinux.org/title/Xorg)
    - [`makepkg`](https://wiki.archlinux.org/title/Makepkg)
    - [`pacman`](https://wiki.archlinux.org/title/Pacman)
    - [`fuse3`](https://man.archlinux.org/man/mount.fuse3.8.en)
    - [`getgroups`](https://man.archlinux.org/man/getgroups.2.en)
    - [`polkit`](https://wiki.archlinux.org/title/Polkit)
    - [`ddcutil`](https://man.archlinux.org/man/extra/ddcutil/ddcutil.1.en)
    - [Locale](https://wiki.archlinux.org/title/Locale)
    - [Steam](https://wiki.archlinux.org/title/Steam)
    - [Wayland](https://wiki.archlinux.org/title/Wayland)
    - [Backlight](https://wiki.archlinux.org/title/Backlight#External_monitors)
    - [`dbus-broker-launch`](https://man.archlinux.org/man/dbus-broker-launch.1.en)
    - [Security](https://wiki.archlinux.org/title/Security)
    - [KDE](https://wiki.archlinux.org/title/KDE)
    - [Distrobox](https://wiki.archlinux.org/title/Distrobox)
    - [Modalias](https://wiki.archlinux.org/title/Modalias)
    - [udev](https://wiki.archlinux.org/title/Udev)
        - [Steam Input Udev Rules](https://github.com/ValveSoftware/steam-devices/blob/master/60-steam-input.rules)
    - [`udisksctl`](https://man.archlinux.org/man/udisksctl.1.en)
    - [Capabilities](https://wiki.archlinux.org/title/Capabilities)
    - [Extended Attributes](https://wiki.archlinux.org/title/Extended_attributes)
    - [Access Control Lists](https://wiki.archlinux.org/title/Access_Control_Lists)
    - [NVIDIA](https://wiki.archlinux.org/title/NVIDIA)
    - [Overlay](https://wiki.archlinux.org/title/Overlay_filesystem)
    - [XDG Desktop Portal](https://wiki.archlinux.org/title/XDG_Desktop_Portal)
    - [Bubblewrap](https://wiki.archlinux.org/title/Bubblewrap/Examples)
    - [DBus](https://wiki.archlinux.org/title/D-Bus)
    - [Pipewire](https://wiki.archlinux.org/title/PipeWire)
    - [Pulse](https://wiki.archlinux.org/title/PulseAudio)
    - [ptrace](https://man.archlinux.org/man/ptrace.2.en)
    - [Flatpak](https://wiki.archlinux.org/title/Flatpak)
    - [AppArmor](https://wiki.archlinux.org/title/AppArmor)
    - [GDM](https://wiki.archlinux.org/title/GDM)
- [Red Hat Blog (& docs)](https://www.redhat.com/en/blog?f[0]=taxonomy_topic_tid:9001#rhdc-search-listing) - similar but for containers (also covers other topics)
    - [logind](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/desktop_migration_and_administration_guide/logind)
    - [Enter... Podman (Tada!)](https://developers.redhat.com/blog/2019/04/24/how-to-run-systemd-in-a-container#)
    - [Podman gaining rootless overlay support](https://www.redhat.com/en/blog/podman-rootless-overlay)
    - [Understanding rootless Podman's user namespace modes](https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes)
    - [Using files and devices in Podman rootless containers](https://www.redhat.com/en/blog/files-devices-podman)
    - [How we achieved a 6-fold increase in Podman startup speed](https://www.redhat.com/en/blog/speed-containers-podman-raspberry-pi)
- [CachyOS Wiki](https://wiki.cachyos.org/)
- [Arch Linux Packages](https://archlinux.org/packages/)
- [CachyOS Packages](https://packages.cachyos.org/)
- [Arch Linux Archive](https://archive.archlinux.org/) - the ALA contains old versions of many packages
- [Arch User Repository (AUR)](https://aur.archlinux.org/)
    - [AUR List Tracker](https://lists.archlinux.org/archives/list/aur-general@lists.archlinux.org/) - if you're considering a reliance on something from AUR, reading on here can give useful insight on if it is safe to do so, what mitigations to take etc. Approach with caution since there have been waves of malicious packages and of the AUR getting DDOSed.
- [`podman-run` documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html)
- [systemd hwdb.d](https://github.com/systemd/systemd/tree/main/hwdb.d)
- [Configuring `xinput`](https://help.wooting.io/article/93-configuring-xinput-support-for-linux)
- [`xpad` driver](https://github.com/paroj/xpad)
- [Gamepad Tester](https://hardwaretester.com/gamepad)
- [`overlayfs` support for rootless containers via `FS_USERNS_MOUNT` in Linux kernel source](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/overlayfs/super.c#n1571)
- [Capabilities manpage](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [X11Docker](https://github.com/mviereck/x11docker) - useful for understanding how to do nicher shenanigans in rootless containers
- [Distrobox](https://github.com/89luca89/distrobox/)
- [Skopeo](https://github.com/podman-container-tools/skopeo)
- [KDE Kiosk Docs](https://develop.kde.org/docs/administration/kiosk/introduction/)
- [NVidia Container Toolkit Release Notes](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/1.19.1/release-notes.html)
    - [Upstream fix for OpenCL issue](https://github.com/NVIDIA/nvidia-container-toolkit/pull/1893)
- [`steamcmd`](https://developer.valvesoftware.com/wiki/SteamCMD)
- [`proton-cachyos`](https://github.com/CachyOS/proton-cachyos)
- [`umu-launcher`](https://github.com/Open-Wine-Components/umu-launcher)
- [Lutris](https://github.com/lutris/lutris)
- [Heroic Games Launcher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher)
- [areweanticheatyet.com](https://areweanticheatyet.com/)
- [ProtonDB](https://www.protondb.com/)
- [DCS System User Guide](https://warwick.ac.uk/fac/sci/dcs/intranet/user_guide/)
- [David Edmundson's Blog Post About Plasma 6.8 Dropping X11 Support](https://blog.davidedmundson.co.uk/blog/596/)

*Some bits e.g. around KDE configs, I intend to write a bit more about in the future - some of them is broadly detailed in [this PR comment](https://github.com/UWCS/fng/pull/14#issue-4696157459)*.

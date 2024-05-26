# Friday Night Gaming System

This project provides an isolated, containerized environment for UWCS event Friday Night Gaming on the department's systems.

## Usage

First install the host requirements onto you user account:

```sh
curl -s https://raw.githubusercontent.com/AlexWright1324/fng/main/install.sh | sh
```

Once the installation is complete, start the environment using (Custom Script) on the user login screen (GDM).

## Details
### Installer

The installer script sets up the following components on your host:

- Distrobox: Manages the container environment.
- `.xsession` - Custom script to start the gaming environment.
- `.config/containers/storage.conf` - Configuration file for Podman storage.
- `.vnc/xstartup` - Configuration file to enable remote access to the container via VNC.

### Image

The container image is based on Docker's Arch Linux. It includes patched in Nvidia support from the host through Distrobox. SystemD is executed within the container to maintain a sandboxed environment.

The `Dockerfile` handles container building, install system components here.

The image is built via a Github Actions workflow and packaged into GHCR, run the workflow via dispatch trigger to update.

Arbitrary Files can be added to the host image via `system-files`.

`/home/fng` is used as the home directory.


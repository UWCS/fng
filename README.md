# Friday Night Gaming Container

Allows DCS Lab Machines to run games in an isolated container.

Want to play games on your DCS Lab Machine with your own account? See below :)
## Usage

First install the host requirements onto you user account:

```sh
curl -s https://raw.githubusercontent.com/UWCS/fng/main/install.sh | sh
```

Once complete, choose "User Script" on the login screen before entering your password.

## How it works
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

## Development
Run `builddev.sh` to build the container tag `fng:dev`
Run `rundev.sh` to execute this image using Xephyr on the lab machines

Requires Xephyr binary installed on lab machines
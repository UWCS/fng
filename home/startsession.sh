#!/bin/bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
dbus-run-session startplasma-x11
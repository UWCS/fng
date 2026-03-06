#!/bin/bash
sudo flatpak remote-delete flathub
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user org.vinegarhq.Sober
dbus-run-session startplasma-x11
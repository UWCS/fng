#!/bin/bash
setxkbmap gb

flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# we allow fusermount to work via SYS_ADMIN but drop +ep from ambient caps so e.g. uns works (otherwise bwrap complains & similar)
# not a nice sln, need to assess better ways of doing at some point
dbus-run-session -- bash -c 'export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS && exec setpriv --ambient-caps="-all" startplasma-x11'

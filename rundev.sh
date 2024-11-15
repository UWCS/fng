#!/bin/bash
# Redirect output to a log file and to the console
exec > >(tee -i -a /tmp/$USER-xsession.log) 2>&1

set -e

# Check if Xephyr is installed
if ! command -v Xephyr &> /dev/null
then
    echo "Xephyr is not installed. Please install Xephyr before running this script."
    exit 1
fi

Xephyr -screen 1280x720 :69 -host-cursor &
XPID=$!
export DISPLAY=:69

# Run the Session
# Get the path to the script dir
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEV=1 $SCRIPT_DIR/host/.xsession

# Kill the Xephyr process
kill $XPID
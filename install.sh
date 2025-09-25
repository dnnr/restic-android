#!/bin/sh
set -o errexit
adb push restic-android.sh /storage/emulated/0
echo -e "Now run in Termux (use Ctrl-V in scrpy, then context menu paste in Android):\ninstall /storage/emulated/0/restic-android.sh ~/"

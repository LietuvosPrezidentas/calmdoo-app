#!/bin/bash
# Sends a test command to a running TEST build of calmdoo (./build.sh install --test-hooks).
# Release builds ignore these. Results land in ~/Library/Logs/calmdoo.log. Dev tool: never ship it.
#   tools/ctl.sh dump                     list apps, volumes and taps
#   tools/ctl.sh debug=on                 log every tap's in/out level once a second
#   tools/ctl.sh com.apple.Safari=0.5     set Safari to 50%
#   tools/ctl.sh master=2                 boost everything to 200%
#   tools/ctl.sh mute=com.spotify.client  toggle mute
#   tools/ctl.sh open | close             show or hide the panel
#   tools/ctl.sh expand=com.apple.Safari  open that app's EQ (expand= closes it)
#   tools/ctl.sh snapshot                 save the open panel to ~/Library/Logs/calmdoo-panel.png
#   tools/ctl.sh output-changed           act as if the output device just switched
set -euo pipefail
osascript -l JavaScript -e "
ObjC.import('Foundation');
\$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.calmdoo.command', '$1', \$(), true);
" >/dev/null

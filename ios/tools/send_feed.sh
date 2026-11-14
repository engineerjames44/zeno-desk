#!/bin/sh
# Push a test feed to the phone, the way the Pi will.
#   PHONE=<phone-ip> tools/send_feed.sh news     (also: call, clear)
# Always finish with "clear" so made-up content doesn't stay on the desk.
: "${PHONE:?set PHONE to the iPhone IP, e.g. PHONE=192.0.2.30 tools/send_feed.sh news}"
curl -s -m 5 -X POST -H 'Content-Type: application/json' \
  --data-binary @"$(dirname "$0")/feeds/${1:-news}.json" "http://$PHONE:8080/feed"
echo

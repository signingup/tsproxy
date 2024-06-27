#!/bin/bash

FILE="/etc/proxy/start.sh"

if [ -f "$FILE" ]; then
  cp "$FILE" /usr/bin/start
  chmod +x /usr/bin/start && /usr/bin/start
fi

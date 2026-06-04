#!/bin/bash
LATEST=$(ls -t /root/Downloads/*.vv 2>/dev/null | head -1)

remote-viewer --full-screen $LATEST &

#!/bin/sh
# Set Xft.dpi from the primary connected output's EDID-reported physical size.
# Best-effort: silently no-ops if xrandr/xrdb is missing or EDID lacks mm info.

command -v xrandr >/dev/null 2>&1 || exit 0
command -v xrdb   >/dev/null 2>&1 || exit 0

line=$(xrandr --query 2>/dev/null | awk '$2=="connected" && /primary/ {print; exit}')
[ -z "$line" ] && line=$(xrandr --query 2>/dev/null | awk '$2=="connected" {print; exit}')
[ -z "$line" ] && exit 0

geom=$(printf '%s\n' "$line" | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -n1)
[ -z "$geom" ] && exit 0
px_w=${geom%%x*}
rest=${geom#*x}
px_h=${rest%%+*}

mm_pair=$(printf '%s\n' "$line" | grep -oE '[0-9]+mm x [0-9]+mm' | head -n1)
[ -z "$mm_pair" ] && exit 0
mm_w=$(printf '%s\n' "$mm_pair" | awk '{print $1}' | tr -d 'm')
mm_h=$(printf '%s\n' "$mm_pair" | awk '{print $3}' | tr -d 'm')

[ "$mm_w" -gt 0 ] 2>/dev/null && [ "$mm_h" -gt 0 ] 2>/dev/null || exit 0

dpi=$(awk -v pw="$px_w" -v ph="$px_h" -v mw="$mm_w" -v mh="$mm_h" \
    'BEGIN { printf "%d", (pw / (mw/25.4) + ph / (mh/25.4)) / 2 + 0.5 }')

[ "$dpi" -lt 72 ]  && dpi=72
[ "$dpi" -gt 240 ] && dpi=240

printf 'Xft.dpi: %s\n' "$dpi" | xrdb -merge

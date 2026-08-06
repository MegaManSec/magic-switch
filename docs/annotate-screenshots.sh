#!/bin/bash
# Regenerate the annotated README screenshots in docs/assets/ from the raw
# captures in docs/assets/raw/. Adds numbered yellow badges + a bottom legend,
# matching the project's existing screenshot style.
#
# Repeatable: recapture a raw screenshot into docs/assets/raw/ (or tweak the
# badge/legend config below) and re-run:
#
#   ./docs/annotate-screenshots.sh
#
# Requires ImageMagick v7 (`magick`) and the referenced macOS system fonts.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="$DIR/assets/raw"
OUT="$DIR/assets"
BADGE_DIR="$(mktemp -d)"
trap 'rm -rf "$BADGE_DIR"' EXIT

YELLOW="#FFD60A"
LIGHT="#EAEAEA"
NUMFONT="/System/Library/Fonts/Supplemental/Arial Bold.ttf"   # badge + legend numbers
TEXTFONT="/System/Library/Fonts/SFNS.ttf"                     # legend body (San Francisco)

# Pre-render badge glyphs 1..6 (36px circle, centered black number).
for n in 1 2 3 4 5 6; do
  magick -size 40x40 xc:none \
    -fill "$YELLOW" -draw "circle 20,20 20,2" \
    -gravity center -font "$NUMFONT" -pointsize 23 -fill black -annotate +0+0 "$n" \
    "$BADGE_DIR/$n.png"
done

# annotate NAME BG BOTTOM_PAD LEGEND_X LEGEND_Y0 LEGEND_DY BADGES LEGEND [LEGEND_PT]
#   reads $RAW/NAME.png, writes $OUT/NAME.png
#   BADGES : newline-separated "num badge_cx badge_cy target_x target_y"
#   LEGEND : newline-separated "num|text"  (blank num => unnumbered continuation)
annotate() {
  local name="$1" bg="$2" pad="$3" lx="$4" ly0="$5" ldy="$6" badges="$7" legend="$8"
  local legpt="${9:-27}"
  local input="$RAW/$name.png" output="$OUT/$name.png"
  [ -f "$input" ] || { echo "skip $name (no raw capture in $RAW)"; return; }
  local W H; read W H < <(magick identify -format "%w %h\n" "$input")

  local args=( "$input" )
  # Pad below for an over-long legend; chop the window's 1px bottom edge first so
  # the join to the flat background is seamless.
  [ "$pad" -gt 0 ] && args+=( -gravity South -chop 0x2 -background "$bg" -gravity NorthWest -extent "${W}x$((H+pad))" )
  args+=( -gravity NorthWest )

  # Leader lines first (the badge circle is drawn on top, hiding the stub).
  args+=( -stroke "$YELLOW" -strokewidth 3 -fill none )
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    set -- $b; args+=( -draw "line $2,$3 $4,$5" )
  done <<< "$badges"

  # Badges: composite pre-rendered glyphs on top of the leader stubs.
  args+=( -stroke none )
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    set -- $b
    args+=( "(" "$BADGE_DIR/$1.png" -geometry "+$(($2-20))+$(($3-20))" ")" -composite )
  done <<< "$badges"

  # Legend (yellow number + light body text), one line per entry.
  local i=0
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    local num="${l%%|*}" text="${l#*|}" y=$((ly0 + i*ldy))
    args+=( -font "$NUMFONT" -pointsize "$legpt" -fill "$YELLOW" -annotate "+${lx}+${y}" "$num" )
    args+=( -font "$TEXTFONT" -pointsize "$legpt" -fill "$LIGHT" -annotate "+$((lx+34))+${y}" "$text" )
    i=$((i+1))
  done <<< "$legend"

  args+=( "$output" )
  magick "${args[@]}"
  echo "wrote $output ($(magick identify -format '%wx%h' "$output"))"
}

# ---- Peripheral tab ----
annotate peripheral-tab "#292929" 0 88 560 47 \
"2 988 145 988 182
3 1105 350 1105 314
1 1050 478 1082 478
4 815 204 855 204" \
"1|Register a Magic device so Magic Switch can manage and hand it off
2|Release — hand this peripheral to the other Mac
3|Remove — stop managing this peripheral
4|Battery level, live while the peripheral is connected to this Mac"

# ---- Peripheral tab: type picker (single badge) ----
annotate peripheral-type-picker "#292929" 0 88 730 47 \
"1 185 158 118 200" \
"1|Click a peripheral's icon to pick a type — or Automatic to auto-detect"

# ---- Macs tab ----
annotate macs-tab "#282828" 0 88 490 47 \
"1 938 270 938 234
2 1028 270 1028 234
3 1105 270 1105 234
4 1025 321 1064 321
5 1166 321 1136 321" \
"1|Ping — check the other Mac is reachable
2|Sync — sync your registered peripherals to that Mac
3|Remove — forget this Mac
4|Add a Mac by IP address — for networks that block Bonjour
5|Refresh — rescan the network for nearby Macs"

# ---- Other tab (scrolled to the shortcut and display sections; legend below the window) ----
annotate other-tab "#292929" 240 88 900 47 \
"1 1055 87 1085 87
2 1055 161 1085 161
3 1030 350 1062 350
4 1055 717 1085 717" \
"1|Release peripherals to the other Mac when this Mac sleeps
2|Reconnect peripherals automatically if they drop
3|Record a shortcut — send, take, or toggle every peripheral from anywhere
4|A marked display — when it connects, peripherals switch to this Mac"

# ---- Menu (translucent material background, smaller legend) ----
annotate menu "#2D2D30" 150 24 405 36 \
"1 462 72 400 72
2 330 172 288 172" \
"1|Click a Mac — move all peripherals there
2|Click a peripheral — move just that one
 |✓ = it's on this Mac now · %% = its battery" 20

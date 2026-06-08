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
annotate peripheral-tab "#292929" 0 88 583 47 \
"2 838 205 895 205
3 1108 352 1108 312
1 1050 483 1092 483" \
"1|Register a Magic device so Magic Switch can manage and hand it off
2|Release — hand this peripheral to the other Mac
3|Remove — stop managing this peripheral"

# ---- Peripheral tab: type picker (single badge) ----
annotate peripheral-type-picker "#292929" 0 88 730 47 \
"1 185 158 118 200" \
"1|Click a peripheral's icon to pick a type — or Automatic to auto-detect"

# ---- Device tab ----
annotate device-tab "#282828" 0 88 465 47 \
"1 932 272 932 230
2 1021 272 1021 230
3 1097 272 1097 230
4 1075 322 1102 322" \
"1|Ping — check the other Mac is reachable
2|Share — sync your registered peripherals to that Mac
3|Remove — forget this Mac
4|Refresh — rescan the network for nearby Macs"

# ---- Other tab (legend extends below the window) ----
annotate other-tab "#292929" 150 88 715 47 \
"1 1055 148 1085 148
2 1055 240 1085 240
3 1055 332 1085 332
4 1078 424 1108 424
5 160 655 160 612" \
"1|Launch at Login — start Magic Switch when you log in
2|Release peripherals to the other Mac when this Mac sleeps
3|Reconnect peripherals automatically if they drop
4|License Information — open-source license details
5|Check for Updates — check now (status shows on the right)"

# ---- Menu (translucent material background, smaller legend) ----
annotate menu "#2D2D30" 150 24 405 36 \
"1 435 72 380 72
2 435 223 380 223" \
"1|Click a Mac — move all peripherals there
2|Click a peripheral — move just that one
 |✓ = it's on this Mac now" 20

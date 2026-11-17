#!/usr/bin/env bash
# umbriel_output_rect gives an effect where its drawn rectangle sits on the output, as fractions of the output's
# logical size: a window effect paints those fractions, and they match the window geometry IPC reports.
set -euo pipefail
readonly IMAGE="$UMBRIEL_RUNTIME_DIR/effect-output-rect.png"

cat > "$UMBRIEL_RUNTIME_DIR/origin.glsl" <<'GLSL'
vec4 window(vec2 uv) { return vec4(umbriel_output_rect.x, umbriel_output_rect.y, umbriel_output_rect.z, 1.0); }
GLSL
cat > "$UMBRIEL_RUNTIME_DIR/extent.glsl" <<'GLSL'
vec4 window(vec2 uv) {
  vec4 r = umbriel_output_rect;
  return vec4(r.x + r.z, r.y + r.w, r.w, 1.0);
}
GLSL

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0
[appearance.shadow]
enabled = false
[animation]
enabled = false
[effects]
in_capture = true
[effects.preset.origin]
kind = "window"
shader = "origin.glsl"
[effects.preset.extent]
kind = "window"
shader = "extent.glsl"
[[window_rule]]
match.title = "^rect-"
default_floating = true
default_floating_size_px = { width = 300, height = 200 }
[[window_rule]]
match.title = "^rect-left$"
default_position = { x = 40, y = 30, anchor = "top_left" }
window_effect = "origin"
[[window_rule]]
match.title = "^rect-right$"
default_position = { x = 60, y = 50, anchor = "bottom_right" }
window_effect = "extent"
EOF
"$UMBRIEL" msg config-reload > /dev/null

read -r out_w out_h < <("$UMBRIEL" outputs --json | jq -r '.[0] | "\(.logical_size.width) \(.logical_size.height)"')

spawn() {
  FILL_COLOR=0xFFFFFFFF "$UMBRIEL_UNMAP_CLIENT" "$1" 300 200 > "$UMBRIEL_RUNTIME_DIR/$1.log" 2>&1 &
  for _ in $(seq 80); do
    [[ -n "$("$UMBRIEL" windows --json | jq -r --arg t "$1" '.[] | select(.title == $t) | .id')" ]] && return 0
    sleep 0.025
  done
  echo "window '$1' never appeared"
  return 1
}

# Asserts one painted channel (0-255) is within 2 of a fraction computed from geometry.
expect_channel() {
  local label=$1 got=$2 numerator=$3 denominator=$4 want
  want=$(((numerator * 255 + denominator / 2) / denominator))
  if ((got < want - 2 || got > want + 2)); then
    echo "$label: painted $got, expected $want ($numerator / $denominator); output ${out_w}x${out_h}"
    exit 1
  fi
}

spawn rect-left
spawn rect-right
"$UMBRIEL" settle
grim "$IMAGE"

read -r x y w h < <("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "rect-left") | "\(.x) \(.y) \(.w) \(.h)"')
read -r r g b < <("$UMBRIEL_PIXEL_PROBE" "$IMAGE" mean "10x10+$((x + w / 2 - 5))+$((y + h / 2 - 5))")
expect_channel "left x" "$r" "$x" "$out_w"
expect_channel "left y" "$g" "$y" "$out_h"
expect_channel "left width" "$b" "$w" "$out_w"

read -r x y w h < <("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "rect-right") | "\(.x) \(.y) \(.w) \(.h)"')
read -r r g b < <("$UMBRIEL_PIXEL_PROBE" "$IMAGE" mean "10x10+$((x + w / 2 - 5))+$((y + h / 2 - 5))")
expect_channel "right edge" "$r" "$((x + w))" "$out_w"
expect_channel "right bottom" "$g" "$((y + h))" "$out_h"
expect_channel "right height" "$b" "$h" "$out_h"

echo "umbriel_output_rect matched both windows' geometry on a ${out_w}x${out_h} output"

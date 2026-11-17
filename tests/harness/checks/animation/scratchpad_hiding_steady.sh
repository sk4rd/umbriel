#!/usr/bin/env bash
# A scratchpad member already on its way out keeps going when the whole pad hides after it: a custom scratchpad
# animation does not start over on a window halfway through its hide.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly SHADER="$UMBRIEL_RUNTIME_DIR/scratchpad-progress.glsl"
readonly FRAME="$UMBRIEL_RUNTIME_DIR/scratchpad-hiding-steady.png"

# Each pixel is scaled by how far the window is through its show or hide, so a restarted hide brightens a fading window.
cat > "$SHADER" <<'EOF'
vec4 animation(vec2 uv) {
  float shown = umbriel_direction > 0.0 ? umbriel_clamped_progress : 1.0 - umbriel_clamped_progress;
  return umbriel_sample(uv) * shown;
}
EOF

cat >> "$UMBRIEL_CONFIG" <<EOF

[animation.windows_in]
enabled = false

[animation.scratchpad]
enabled = true
duration_ms = 2000
curve = "linear"
dim = 0.0
blur = false
effect = "progress"

[effects.preset.progress]
kind = "animation"
shader = "$SHADER"

[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0

[appearance.shadow]
enabled = false

[[window_rule]]
match.title = "^pad-"
default_scratchpad = "default"
default_floating_size_px = { width = 300, height = 200 }

[[window_rule]]
match.title = "^pad-red$"
default_position = { x = 100, y = 0, anchor = "left" }

[[window_rule]]
match.title = "^pad-green$"
default_position = { x = 100, y = 0, anchor = "right" }
EOF
"$UMBRIEL" msg config-reload > /dev/null

window_of() { "$UMBRIEL" windows --json | jq -c --arg title "$1" '.[] | select(.title == $title)'; }

spawn() {
  local title=$1 color=$2
  FILL_COLOR="$color" "$CLIENT" "$title" 300 200 > "$UMBRIEL_RUNTIME_DIR/$title.log" 2>&1 &
  for _ in $(seq 80); do
    [[ -n "$(window_of "$title")" ]] && return 0
    sleep 0.025
  done
  echo "window '$title' never appeared: $(cat "$UMBRIEL_RUNTIME_DIR/$title.log")"
  return 1
}

# Mean of one channel over the middle of a window, 0-255.
channel() {
  local title=$1 field=$2 x y w h
  read -r x y w h < <(window_of "$title" | jq -r '"\(.x) \(.y) \(.w) \(.h)"')
  "$UMBRIEL_PIXEL_PROBE" "$FRAME" mean "20x20+$((x + w / 2 - 10))+$((y + h / 2 - 10))" | awk -v f="$field" '{ print $f }'
}

spawn pad-red 0xFFFF0000
spawn pad-green 0xFF00FF00

# Animation time only moves by clock-advance: 2000 ms finishes any scratchpad fade.
"$UMBRIEL" clock-freeze
"$UMBRIEL" msg scratchpad-toggle > /dev/null
"$UMBRIEL" clock-advance 2000

# Red goes first and is halfway out when green, the last one on show, hides the pad.
"$UMBRIEL" msg scratchpad-window-toggle "$(window_of pad-red | jq -r .id)" > /dev/null
"$UMBRIEL" clock-advance 1000
"$UMBRIEL" msg scratchpad-window-toggle "$(window_of pad-green | jq -r .id)" > /dev/null
"$UMBRIEL" clock-advance 300
grim "$FRAME"
red=$(channel pad-red 1)
green=$(channel pad-green 2)
# 1300 ms into its 2000 ms hide red is near 89; a hide restarted with green would put it near 217.
if ((red > 130)); then
  echo "red was halfway out when the pad hid, but its scratchpad animation started again: red=$red"
  exit 1
fi
if ((green < 150 || green > 240)); then
  echo "green should be just into its hide 300 ms in: green=$green"
  exit 1
fi

echo "a member already hiding kept its progress when the pad hid after it: red=$red green=$green"

#!/usr/bin/env bash
# A scratchpad member that stays on show while the pad changes what it shows keeps its fade at rest: a custom
# scratchpad animation does not play again on a window that never left the screen.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly SHADER="$UMBRIEL_RUNTIME_DIR/scratchpad-progress.glsl"
readonly FRAME="$UMBRIEL_RUNTIME_DIR/scratchpad-shown-steady.png"

# Each pixel is scaled by how far the window is through its show or hide, so a restarted show dims a steady window.
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
grim "$FRAME"
red=$(channel pad-red 1)
green=$(channel pad-green 2)
if ((red < 230 || green < 230)); then
  echo "both pad windows should be on show before the step: red=$red green=$green"
  exit 1
fi

# From every window shown, the step after the focused red window keeps only green; 300 ms in, red is fading out.
"$UMBRIEL" msg window-focus "$(window_of pad-red | jq -r .id)" > /dev/null
"$UMBRIEL" msg scratchpad-window-show-next > /dev/null
"$UMBRIEL" clock-advance 300
grim "$FRAME"
red=$(channel pad-red 1)
green=$(channel pad-green 2)
if ((red < 40 || red > 230)); then
  echo "red should be part way through its hide 300 ms in: red=$red"
  exit 1
fi
if ((green < 230)); then
  echo "green stayed on show but its scratchpad animation started again: green=$green"
  exit 1
fi

# Toggling red back in beside green leaves green at rest while red fades in.
"$UMBRIEL" clock-advance 2000
"$UMBRIEL" msg scratchpad-window-toggle "$(window_of pad-red | jq -r .id)" > /dev/null
"$UMBRIEL" clock-advance 300
grim "$FRAME"
red=$(channel pad-red 1)
green=$(channel pad-green 2)
if ((red < 10 || red > 200)); then
  echo "red should be part way through its show 300 ms in: red=$red"
  exit 1
fi
if ((green < 230)); then
  echo "green stayed on show while red was toggled in, but its scratchpad animation started again: green=$green"
  exit 1
fi

echo "members that stayed on show kept their fade at rest while others hid or showed: red=$red green=$green"

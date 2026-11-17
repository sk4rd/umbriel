#!/usr/bin/env bash
# scratchpad-window-toggle shows or hides one window of a scratchpad and leaves the others as they are. On a hidden pad
# it shows only that window, hiding the last window on show hides the pad, focus leaves a window that hides, and closing
# one of several windows on show keeps the rest.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly FRAME="$UMBRIEL_RUNTIME_DIR/window-toggle.png"

if [[ ! -x $CLIENT ]]; then
  echo "unmap client is not built"
  exit 1
fi

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[animation.scratchpad]
dim = 0.0
blur = false

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
default_position = { x = 40, y = 0, anchor = "left" }

[[window_rule]]
match.title = "^pad-green$"
default_position = { x = 0, y = 0, anchor = "center" }

[[window_rule]]
match.title = "^pad-blue$"
default_position = { x = 40, y = 0, anchor = "right" }
EOF
"$UMBRIEL" msg config-reload > /dev/null

window_of() { "$UMBRIEL" windows --json | jq -c --arg title "$1" '.[] | select(.title == $title)'; }
id_of() { window_of "pad-$1" | jq -r .id; }

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

# Which of the three colours are on screen, as a space-separated list.
shown() {
  "$UMBRIEL" settle
  grim "$FRAME"
  local visible=() w h
  read -r _ _ w h < <("$UMBRIEL_PIXEL_PROBE" "$FRAME" bbox 'r > 0.9 && g < 0.1 && b < 0.1')
  ((w > 0 && h > 0)) && visible+=(red)
  read -r _ _ w h < <("$UMBRIEL_PIXEL_PROBE" "$FRAME" bbox 'g > 0.9 && r < 0.1 && b < 0.1')
  ((w > 0 && h > 0)) && visible+=(green)
  read -r _ _ w h < <("$UMBRIEL_PIXEL_PROBE" "$FRAME" bbox 'b > 0.9 && r < 0.1 && g < 0.1')
  ((w > 0 && h > 0)) && visible+=(blue)
  echo "${visible[*]}"
}

expect() {
  local label=$1 expected=$2 actual
  actual=$(shown)
  if [[ $actual != "$expected" ]]; then
    echo "after $label expected [$expected] on screen, got [$actual]"
    exit 1
  fi
}

toggle() {
  "$UMBRIEL" msg scratchpad-window-toggle "$(id_of "$1")" > /dev/null
  expect "toggling $1" "$2"
}

expect_active() {
  local actual
  actual=$("$UMBRIEL" windows --json | jq -r '.[] | select(.active) | .title')
  if [[ $actual != "pad-$1" ]]; then
    echo "$2: expected pad-$1 to have focus, got [$actual]"
    exit 1
  fi
}

spawn pad-red 0xFFFF0000
spawn pad-green 0xFF00FF00
pid_green=$!
spawn pad-blue 0xFF0000FF
expect setup ""

toggle red "red"
expect_active red "showing a window on a hidden pad"
toggle green "red green"
expect_active green "adding a window to the ones on show"
toggle blue "red green blue"
toggle green "red blue"
expect_active blue "hiding a window without focus"
toggle blue "red"
expect_active red "hiding the focused window"
toggle red ""

# From every window shown by scratchpad-toggle, it hides just the one named.
"$UMBRIEL" msg scratchpad-toggle > /dev/null
expect scratchpad-toggle "red green blue"
toggle red "green blue"

# The step actions keep a single window; the toggle adds to it again.
"$UMBRIEL" msg window-focus "$(id_of green)" > /dev/null
"$UMBRIEL" msg scratchpad-window-show-next > /dev/null
expect scratchpad-window-show-next "blue"
toggle green "green blue"

# Closing one of several windows on show keeps the rest.
kill "$pid_green"
for _ in $(seq 80); do
  [[ -z "$(window_of pad-green)" ]] && break
  sleep 0.025
done
expect "closing green" "blue"

# A window outside every scratchpad is refused.
spawn plain 0xFFFFFFFF
if "$UMBRIEL" msg scratchpad-window-toggle "$(window_of plain | jq -r .id)" > /dev/null 2>&1; then
  echo "scratchpad-window-toggle accepted a window that is in no scratchpad"
  exit 1
fi

echo "scratchpad-window-toggle showed and hid single windows while the rest stayed as they were"

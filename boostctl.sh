#!/usr/bin/env bash
# Loudness Boost backend.
#
# Runs a system-wide gain + limiter in an isolated PipeWire instance, exposed
# as a virtual sink. Turning the boost on makes that sink the default output
# and moves existing streams onto it; turning it off restores the real output.
set -euo pipefail

SINK="loudness_boost_sink"
SERVICE="omarchy-loudness-boost.service"
LIMITER_URI="http://lsp-plug.in/plugins/lv2/limiter_stereo"

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
HOST_CONF="$CONFIG_HOME/pipewire/omarchy-loudness-boost.conf"
DROPIN_DIR="$HOST_CONF.d"
FILTER_CONF="$DROPIN_DIR/90-boost.conf"
UNIT_DIR="$CONFIG_HOME/systemd/user"
UNIT="$UNIT_DIR/$SERVICE"
STATE_DIR="$CONFIG_HOME/omarchy-loudness-boost"
GAIN_FILE="$STATE_DIR/gain-db"
PREV_FILE="$STATE_DIR/previous-sink"

DEFAULT_GAIN_DB=9
MIN_GAIN_DB=0
MAX_GAIN_DB=30
# -1 dB, leaves a little headroom so the limiter does not sit on the ceiling.
THRESHOLD="0.891"

die() { echo "loudness-boost: $*" >&2; exit 1; }

mkdir -p "$DROPIN_DIR" "$UNIT_DIR" "$STATE_DIR"

gain_db() { cat "$GAIN_FILE" 2>/dev/null || echo "$DEFAULT_GAIN_DB"; }

clamp_gain() {
  awk -v g="$1" -v lo="$MIN_GAIN_DB" -v hi="$MAX_GAIN_DB" \
    'BEGIN { if (g < lo) g = lo; if (g > hi) g = hi; printf "%.1f", g }'
}

gain_linear() { awk -v d="$1" 'BEGIN { printf "%.6f", 10 ^ (d / 20) }'; }

sink_exists() {
  pactl list sinks short 2>/dev/null | awk -v s="$SINK" '$2 == s { f = 1 } END { exit !f }'
}

sink_named() {
  pactl list sinks short 2>/dev/null | awk -v s="$1" '$2 == s { f = 1 } END { exit !f }'
}

# The real output: the current default unless it is ours, otherwise the first
# sink that is not ours.
real_sink() {
  local d
  d="$(pactl get-default-sink 2>/dev/null || true)"
  if [[ -n $d && $d != "$SINK" ]]; then
    echo "$d"
    return
  fi
  pactl list sinks short 2>/dev/null | awk -v s="$SINK" '$2 != s { print $2; exit }'
}

service_active() { [[ $(systemctl --user is-active "$SERVICE" 2>/dev/null) == active ]]; }

node_id() {
  pw-dump 2>/dev/null |
    jq -r --arg s "$SINK" \
      '.[] | select(.type == "PipeWire:Interface:Node")
           | select(.info.props["node.name"] == $s) | .id' | head -1
}

move_streams() {
  local target="$1" idx
  # Never move the boost's own playback stream back into itself.
  for idx in $(pactl -f json list sink-inputs 2>/dev/null |
    jq -r '.[] | select((.properties["node.name"] // "") | startswith("loudness_boost") | not) | .index'); do
    pactl move-sink-input "$idx" "$target" >/dev/null 2>&1 || true
  done
}

write_host_conf() {
  cat > "$HOST_CONF" <<'EOF'
# Created by the Loudness Boost Omarchy plugin.
context.properties = { log.level = 0 }
context.spa-libs = {
  audio.convert.* = audioconvert/libspa-audioconvert
  support.* = support/libspa-support
}
context.modules = [
  { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
]
EOF
}

write_filter() {
  local target="$1" gain="$2" g_in
  g_in="$(gain_linear "$gain")"
  cat > "$FILTER_CONF" <<EOF
# Created by the Loudness Boost Omarchy plugin.
context.modules = [
  { name = libpipewire-module-filter-chain args = {
    node.description = "Loudness Boost"
    media.name = "Loudness Boost"
    filter.graph = {
      nodes = [
        { type = lv2 name = limiter
          plugin = "$LIMITER_URI"
          control = { "alr" = 0 "boost" = 0 "g_in" = $g_in "th" = $THRESHOLD } }
      ]
      inputs = [ "limiter:in_l" "limiter:in_r" ]
      outputs = [ "limiter:out_l" "limiter:out_r" ]
    }
    audio.channels = 2
    audio.position = [ FL FR ]
    capture.props = { node.name = "$SINK" media.class = Audio/Sink }
    playback.props = {
      node.name = "${SINK}_output"
      node.passive = true
      target.object = "$target"
      node.dont-move = true
      node.dont-fallback = true
      node.linger = true
    }
  } }
]
EOF
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Loudness Boost filter chain
After=pipewire.service wireplumber.service
Requires=pipewire.service
Wants=wireplumber.service
PartOf=pipewire.service

[Service]
Type=simple
ExecStart=/usr/bin/pipewire -c $(basename "$HOST_CONF")
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF
}

emit_status() {
  local active=false
  service_active && sink_exists && active=true
  printf '{"active":%s,"gainDb":%s,"minDb":%s,"maxDb":%s,"sink":"%s","previousSink":"%s"}\n' \
    "$active" "$(gain_db)" "$MIN_GAIN_DB" "$MAX_GAIN_DB" "$SINK" \
    "$(cat "$PREV_FILE" 2>/dev/null || echo "")"
}

cmd_enable() {
  local want="${1:-}" gain target i
  target="$(real_sink)"
  [[ -n $target ]] || die "no output device found"
  if [[ -n $want ]]; then
    clamp_gain "$want" > "$GAIN_FILE"
  fi
  gain="$(gain_db)"
  echo "$target" > "$PREV_FILE"
  write_host_conf
  write_filter "$target" "$gain"
  write_unit
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE" >/dev/null 2>&1 || true
  for i in $(seq 1 40); do sink_exists && break; sleep 0.1; done
  sink_exists || die "boost output did not start (journalctl --user -u $SERVICE)"
  pactl set-default-sink "$SINK"
  move_streams "$SINK"
  emit_status
}

cmd_disable() {
  local prev
  prev="$(cat "$PREV_FILE" 2>/dev/null || true)"
  if [[ -z $prev ]] || ! sink_named "$prev"; then
    prev="$(real_sink)"
  fi
  if [[ -n $prev && $prev != "$SINK" ]]; then
    pactl set-default-sink "$prev" >/dev/null 2>&1 || true
    move_streams "$prev"
  fi
  systemctl --user disable --now "$SERVICE" >/dev/null 2>&1 || true
  emit_status
}

cmd_set() {
  local gain node g_in
  [[ -n ${1:-} ]] || die "set needs a gain in dB"
  gain="$(clamp_gain "$1")"
  echo "$gain" > "$GAIN_FILE"
  if service_active && sink_exists; then
    node="$(node_id)"
    if [[ -n $node ]]; then
      g_in="$(gain_linear "$gain")"
      pw-cli set-param "$node" Props \
        "{ params = [ \"limiter:g_in\" $g_in ] }" >/dev/null 2>&1 || true
    fi
  fi
  emit_status
}

cmd_toggle() {
  if service_active && sink_exists; then cmd_disable; else cmd_enable; fi
}

case "${1:-status}" in
  status) emit_status ;;
  enable) shift; cmd_enable "$@" ;;
  disable) cmd_disable ;;
  toggle) cmd_toggle ;;
  set) shift; cmd_set "$@" ;;
  *) die "usage: boostctl.sh [status|enable [db]|disable|toggle|set <db>]" ;;
esac
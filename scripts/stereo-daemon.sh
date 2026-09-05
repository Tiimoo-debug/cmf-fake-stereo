#!/system/bin/sh
# Applies the routing actions and keeps them applied.
#
# The audio HAL rewrites mixer controls on every route change (stream start,
# device switch, call), so a one-shot write does not survive. This polls and
# re-asserts. It only holds the earpiece energised while audio is actually
# playing, unless MODE=always.

MODDIR=${MODDIR:-/data/adb/modules/cmf_stereo}
. "$MODDIR/scripts/common.sh"

rotate_log
echo $$ > "$PIDFILE"
trap 'log info "daemon stopping"; revert_actions; rm -f "$PIDFILE"; exit 0' TERM INT

# Wait for boot to finish so the HAL has settled before we touch anything.
_w=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ $_w -lt 120 ]; do
  sleep 2
  _w=$((_w + 2))
done
sleep "${STARTUP_DELAY:-10}"

if [ "$(action_count)" -eq 0 ]; then
  log info "no actions configured - nothing to do (run 'stereoctl probe' first)"
  rm -f "$PIDFILE"
  exit 0
fi

if ! find_tinymix && action_lines | grep -q '^[[:space:]]*ctl'; then
  log warn "tinymix not found but ctl actions are configured; they will be skipped"
fi

log info "daemon started (mode=$MODE interval=${WATCH_INTERVAL}s actions=$(action_count))"

applied=0

while true; do
  # Re-read config each cycle so stereoctl edits take effect without a reboot.
  [ -f "$CONF" ] && . "$CONF"

  if ! module_active; then
    [ $applied -eq 1 ] && { revert_actions; applied=0; log info "disabled - reverted"; }
    sleep "${WATCH_INTERVAL:-2}"
    continue
  fi

  want=0
  case $MODE in
    always)   want=1 ;;
    *)        playback_active && speaker_route_active && want=1 ;;
  esac

  if [ $want -eq 1 ]; then
    # Re-assert unconditionally: apply_actions is a no-op for controls that
    # already hold the wanted value, so this is cheap when nothing changed.
    apply_actions
    [ $applied -eq 0 ] && log info "stereo engaged"
    applied=1
  elif [ $applied -eq 1 ]; then
    revert_actions
    applied=0
    log info "playback stopped - reverted"
  fi

  sleep "${WATCH_INTERVAL:-2}"
done

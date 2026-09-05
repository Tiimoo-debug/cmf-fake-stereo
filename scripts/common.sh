#!/system/bin/sh
# Shared helpers for the CMF Phone 1 stereo module.
# Sourced by post-fs-data.sh, service.sh, stereoctl and probe.sh.

MODID=cmf_stereo
MODDIR=${MODDIR:-/data/adb/modules/$MODID}
# Overridable so the scripts can be exercised off-device.
DATADIR=${DATADIR:-/data/adb/cmf-stereo}

CONF=$DATADIR/stereo.conf
ACTIONS=$DATADIR/actions.conf
STATEDIR=$DATADIR/state
LOGFILE=$DATADIR/stereo.log
PIDFILE=$DATADIR/daemon.pid
KILLSWITCH=$DATADIR/disabled

# Defaults, overridden by stereo.conf.
ENABLED=1
MODE=playback
WATCH_INTERVAL=2
LOG_LEVEL=info
LOG_MAX_KB=512
MIXER_CARD=

mkdir -p "$DATADIR" "$STATEDIR" 2>/dev/null

[ -f "$CONF" ] && . "$CONF"

##############################################################################
# logging
##############################################################################

log() {
  # log <level> <message...>
  _lvl=$1; shift
  case $LOG_LEVEL in
    debug) ;;
    info)  [ "$_lvl" = debug ] && return 0 ;;
    warn)  case $_lvl in debug|info) return 0 ;; esac ;;
    *)     [ "$_lvl" = debug ] && return 0 ;;
  esac
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*" >> "$LOGFILE"
}

rotate_log() {
  [ -f "$LOGFILE" ] || return 0
  _kb=$(( $(stat -c %s "$LOGFILE" 2>/dev/null || echo 0) / 1024 ))
  [ "$_kb" -gt "${LOG_MAX_KB:-512}" ] && mv -f "$LOGFILE" "$LOGFILE.1"
  return 0
}

##############################################################################
# tinymix discovery + calling convention
##############################################################################

# Not every vendor ships tinymix. We look in the usual places, including a
# copy the user dropped into the module's bin/ directory.
find_tinymix() {
  [ -n "${TINYMIX:-}" ] && [ -x "$TINYMIX" ] && return 0
  for _c in \
    "$MODDIR/bin/tinymix" \
    /data/adb/cmf-stereo/bin/tinymix \
    /vendor/bin/tinymix \
    /system/bin/tinymix \
    /system/vendor/bin/tinymix \
    /odm/bin/tinymix \
    /data/local/tmp/tinymix
  do
    [ -x "$_c" ] && { TINYMIX=$_c; return 0; }
  done
  # Anything a another module put on PATH.
  _c=$(command -v tinymix 2>/dev/null)
  [ -n "$_c" ] && { TINYMIX=$_c; return 0; }
  TINYMIX=
  return 1
}

# tinyalsa 2.x uses "tinymix get/set NAME", older builds use "tinymix NAME [val]".
# Detect once and cache for the life of the process.
#
# Detection goes through --help, which 2.x answers even with no sound card
# present. Do not match on the error text from a bare "tinymix get": 2.x
# answers that with "no control specified", which reads nothing like a usage
# message, and guessing "old" from it makes every later write a silent no-op.
tinymix_style() {
  [ -n "${TINYMIX_STYLE:-}" ] && { echo "$TINYMIX_STYLE"; return 0; }
  _help=$("$TINYMIX" --help 2>&1)
  _get=$("$TINYMIX" get 2>&1)
  if echo "$_help" | grep -qE 'get[[:space:]]+(NAME|<|\[)'; then
    TINYMIX_STYLE=new
  elif echo "$_get" | grep -qi 'no control specified'; then
    TINYMIX_STYLE=new
  elif [ -z "$_help" ] && [ -z "$_get" ]; then
    # Says nothing to either probe: wrong architecture, or not executable.
    # Reporting a style here would turn every later write into a silent no-op.
    TINYMIX_STYLE=unknown
  else
    TINYMIX_STYLE=old
  fi
  echo "$TINYMIX_STYLE"
}

_card_args() {
  [ -n "$MIXER_CARD" ] && echo "-D $MIXER_CARD"
}

ctl_get() {
  # ctl_get <control name> -> prints current value, empty on failure
  find_tinymix || return 1
  [ "$(tinymix_style)" = unknown ] && return 1
  _out=$(
    if [ "$(tinymix_style)" = new ]; then
      # shellcheck disable=SC2046
      "$TINYMIX" $(_card_args) get "$1" 2>/dev/null
    else
      # shellcheck disable=SC2046
      "$TINYMIX" $(_card_args) "$1" 2>/dev/null
    fi
  )
  # Old tinymix echoes a header line before the value; keep the last non-empty
  # line and strip any ">" cursor decoration around enum values.
  echo "$_out" | grep -v '^[[:space:]]*$' | tail -n 1 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^>//'
}

ctl_set() {
  # ctl_set <control name> <value>
  find_tinymix || return 1
  [ "$(tinymix_style)" = unknown ] && return 1
  if [ "$(tinymix_style)" = new ]; then
    # shellcheck disable=SC2046
    "$TINYMIX" $(_card_args) set "$1" "$2" >/dev/null 2>&1
  else
    # shellcheck disable=SC2046
    "$TINYMIX" $(_card_args) "$1" "$2" >/dev/null 2>&1
  fi
}

ctl_exists() {
  find_tinymix || return 1
  [ -n "$(ctl_get "$1")" ]
}

##############################################################################
# playback detection
##############################################################################

# True while any playback substream is RUNNING. Cheap enough to poll: it is a
# handful of procfs reads, no dumpsys, no binder.
playback_active() {
  for _s in /proc/asound/card*/pcm*p/sub*/status; do
    [ -f "$_s" ] || continue
    grep -q '^state: RUNNING' "$_s" 2>/dev/null && return 0
  done
  return 1
}

# Best-effort check that audio is going out of the speaker rather than
# headphones/BT. If we cannot tell, we say yes and let the actions decide.
speaker_route_active() {
  [ "${REQUIRE_SPEAKER_ROUTE:-0}" = 1 ] || return 0
  _dump=$(dumpsys audio 2>/dev/null | head -n 200)
  [ -z "$_dump" ] && return 0
  echo "$_dump" | grep -qiE 'BLUETOOTH_A2DP|WIRED_HEADPHONE|WIRED_HEADSET|USB_HEADSET' && return 1
  return 0
}

##############################################################################
# action engine
#
# actions.conf holds one action per line:
#   ctl|<mixer control name>|<value>
#   sysfs|<path>|<value>
#   prop|<property>|<value>
# Blank lines and lines starting with '#' are ignored.
##############################################################################

_state_key() {
  echo "$1_$2" | tr -c 'A-Za-z0-9._-' '_'
}

action_lines() {
  [ -f "$ACTIONS" ] || return 0
  grep -v '^[[:space:]]*#' "$ACTIONS" | grep -v '^[[:space:]]*$'
}

action_count() {
  action_lines | wc -l | tr -d ' '
}

# Remember the pre-module value once, so revert puts the device back.
_save_original() {
  # _save_original <kind> <target> <current value>
  _f=$STATEDIR/$(_state_key "$1" "$2")
  [ -f "$_f" ] && return 0
  printf '%s' "$3" > "$_f"
}

_original() {
  _f=$STATEDIR/$(_state_key "$1" "$2")
  [ -f "$_f" ] && cat "$_f"
}

apply_actions() {
  action_lines | while IFS='|' read -r kind target value rest; do
    kind=$(echo "$kind" | tr -d ' ')
    target=$(echo "$target" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$kind" ] && [ -n "$target" ] || continue
    case $kind in
      ctl)
        _cur=$(ctl_get "$target")
        if [ -z "$_cur" ]; then
          log warn "mixer control not found: $target"
          continue
        fi
        _save_original ctl "$target" "$_cur"
        [ "$_cur" = "$value" ] && continue
        if ctl_set "$target" "$value"; then
          log info "ctl '$target': $_cur -> $value"
        else
          log warn "ctl '$target': failed to set $value"
        fi
        ;;
      sysfs)
        if [ ! -e "$target" ]; then
          log warn "sysfs node missing: $target"
          continue
        fi
        _cur=$(cat "$target" 2>/dev/null)
        _save_original sysfs "$target" "$_cur"
        [ "$_cur" = "$value" ] && continue
        if echo "$value" > "$target" 2>/dev/null; then
          log info "sysfs '$target': $_cur -> $value"
        else
          log warn "sysfs '$target': write denied (SELinux or read-only)"
        fi
        ;;
      prop)
        _cur=$(getprop "$target")
        _save_original prop "$target" "$_cur"
        [ "$_cur" = "$value" ] && continue
        if command -v resetprop >/dev/null 2>&1; then
          resetprop -n "$target" "$value" && log info "prop '$target': $_cur -> $value"
        else
          setprop "$target" "$value" && log info "prop '$target': $_cur -> $value"
        fi
        ;;
      *)
        log warn "unknown action kind: $kind"
        ;;
    esac
  done
}

revert_actions() {
  action_lines | while IFS='|' read -r kind target value rest; do
    kind=$(echo "$kind" | tr -d ' ')
    target=$(echo "$target" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$kind" ] && [ -n "$target" ] || continue
    _orig=$(_original "$kind" "$target")
    [ -n "$_orig" ] || continue
    case $kind in
      ctl)   ctl_set "$target" "$_orig" && log info "ctl '$target' restored to $_orig" ;;
      sysfs) echo "$_orig" > "$target" 2>/dev/null && log info "sysfs '$target' restored to $_orig" ;;
      prop)
        if command -v resetprop >/dev/null 2>&1; then
          resetprop -n "$target" "$_orig"
        else
          setprop "$target" "$_orig"
        fi
        ;;
    esac
  done
}

module_active() {
  [ -f "$KILLSWITCH" ] && return 1
  [ "${ENABLED:-1}" = 1 ]
}

daemon_pid() {
  [ -f "$PIDFILE" ] || return 1
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] && [ -d "/proc/$_p" ] && { echo "$_p"; return 0; }
  return 1
}

##############################################################################
# XML sanity
#
# There is no xmllint on Android, and a malformed audio policy takes the audio
# HAL down hard enough to bootloop the phone. So before any patched policy is
# allowed into the overlay it has to survive these structural checks.
##############################################################################

xml_sane() {
  # xml_sane <file> -> 0 if the file looks structurally intact
  _f=$1
  [ -s "$_f" ] || { echo "empty file"; return 1; }

  # Container elements are checked too: <devicePorts> differs from
  # <devicePort> by one character, and losing one is invisible otherwise.
  for _tag in module modules mixPort mixPorts devicePort devicePorts \
              route routes audioPolicyConfiguration; do
    # Self-closing elements (<devicePort ... />) count as open+close.
    _open=$(grep -o "<$_tag[ >]" "$_f" 2>/dev/null | wc -l)
    _close=$(grep -o "</$_tag>" "$_f" 2>/dev/null | wc -l)
    _self=$(grep -o "<$_tag[^>]*/>" "$_f" 2>/dev/null | wc -l)
    if [ "$_open" -ne $((_close + _self)) ]; then
      echo "unbalanced <$_tag>: $_open open, $_close close, $_self self-closing"
      return 1
    fi
  done

  grep -q '</audioPolicyConfiguration>' "$_f" || {
    echo "missing root closing tag (file truncated?)"; return 1; }

  # A stray backslash is the signature of a bad sed/awk insertion.
  grep -q '\\$' "$_f" && { echo "trailing backslash - bad line insertion"; return 1; }

  return 0
}

##############################################################################
# boot watchdog
#
# Counts boots that started with our changes active but never reached
# sys.boot_completed. Two strikes and the module disarms itself, so a bad
# config costs a reboot rather than a trip to recovery.
##############################################################################

BOOTCOUNT=$DATADIR/boot_pending

boot_strikes() {
  [ -f "$BOOTCOUNT" ] && cat "$BOOTCOUNT" 2>/dev/null || echo 0
}

boot_strike_add() {
  echo $(( $(boot_strikes) + 1 )) > "$BOOTCOUNT"
}

boot_strike_clear() {
  echo 0 > "$BOOTCOUNT"
}

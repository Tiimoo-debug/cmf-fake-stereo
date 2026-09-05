#!/system/bin/sh
# Stop the daemon and put every touched control back before the module goes.

MODDIR=/data/adb/modules/cmf_stereo
if [ -f "$MODDIR/scripts/common.sh" ]; then
  . "$MODDIR/scripts/common.sh"
  if _p=$(daemon_pid); then kill "$_p" 2>/dev/null; sleep 1; fi
  revert_actions
fi

# Keep the config and probe reports: reinstalling should not lose the routing
# you worked out. Remove /data/adb/cmf-stereo by hand for a clean slate.
rm -f /data/adb/cmf-stereo/daemon.pid /data/adb/cmf-stereo/boot_pending

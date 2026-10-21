#!/bin/sh
# Unhealthy khi: systemd chưa boot xong, hoặc có unit ở trạng thái failed.
state=$(systemctl is-system-running 2>/dev/null)

case "$state" in
  running)  exit 0 ;;
  starting|initializing) exit 1 ;;   # chưa boot xong -> để start-period lo
  degraded)
      echo "degraded - unit failed:"
      systemctl --failed --no-legend --no-pager | sed 's/^/  /'
      exit 1 ;;
  *)  echo "systemd state: ${state:-không trả lời}"; exit 1 ;;
esac

#!/bin/sh
# Feed smartctl data into collectd (multi-DS)
# to integrate with exec plugin of collectd

HOSTNAME="${COLLECTD_HOSTNAME:-ice_nas_new}"
INTERVAL="${COLLECTD_INTERVAL:-60}"

DISK="$1"
DRIVER="$2"

if [ -z "$DISK" ]; then
	echo "Usage: $0 <disk_device> [driver]" >&2
	exit 1
fi

SMART_ARGS="-j -A"
[ -n "$DRIVER" ] && SMART_ARGS="$SMART_ARGS -d $DRIVER"

while true; do
	smartctl $SMART_ARGS "/dev/$DISK" 2>/dev/null | jq -r '
		.ata_smart_attributes.table[] |
		.id as $id |
		(("00" + ($id|tostring))[-3:]) as $id3 |
		.name as $name |
		# values with fallback to U
		(.value // "U") as $current |
		(.worst // "U") as $worst |
		(.thresh // "U") as $threshold |
		(.raw.value // "U") as $raw |

		"PUTVAL \"'$HOSTNAME'/smart-'${DISK}'/smart_attribute-ctl-" +
		$id3 + "-" + $name + 
		"\" interval='$INTERVAL' N:" +
		($current|tostring) + ":" +
		($worst|tostring) + ":" +
		($threshold|tostring) + ":" +
		# one raw for pretty as smartctl doesnt calculate real pretty ones as libsata tries to do:
		($raw|tostring) + ":" +
		($raw|tostring)
	'

	sleep "${INTERVAL%.*}"
done
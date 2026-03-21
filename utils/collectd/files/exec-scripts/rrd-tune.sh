#!/bin/sh
set -e
# Audit or fix RRD parameters against collectd rrdtool plugin configuration.
#
# Usage: rrd-tune.sh <config_file> <operation>
#   config_file  path to collectd config (e.g. /var/etc/collectd.conf)
#   operation    fix    - fix all mismatched parameters
#                report - print all mismatches, exit 1 if any found
#
# Parameters checked and fixed:
#   step        - per plugin interval, fixed via dump/restore when rrd != interval
#   heartbeat   - 1.01x interval rounded up, fixed via rrdtool tune
#   rra count   - from RRATimespan count * (1 or 3 depending on RRASingle)
#   pdp_per_row - RRATimespan / (RRARows * step), per RRA
#   rows        - RRARows setting
#   xff         - XFF setting (default 0.1)
#
# All dump/restore operations use temp files alongside the RRD itself.
#
# Called from /etc/init.d/collectd start_service():
#   rrd-tune.sh "${config_file}" fix

COLLECTD_CONF="${1}"
OP="${2}"

usage() {
	echo "Usage: $0 <config_file> <fix|report>" >&2
	exit 2
}

[ -n "$COLLECTD_CONF" ] || usage
[ "$OP" = "fix" ] || [ "$OP" = "report" ] || usage

[ -f "$COLLECTD_CONF" ] || {
	echo "rrd-tune: $COLLECTD_CONF not found" >&2
	exit 1
}

RRD_BASE=$(uci -q get luci_statistics.collectd_rrdtool.DataDir 2>/dev/null)
RRD_BASE="${RRD_BASE:-/tmp/rrd}"

[ -d "$RRD_BASE" ] || {
	echo "rrd-tune: RRD dir $RRD_BASE not found" >&2
	exit 1
}

DEFAULT_INTERVAL=$(awk '/^Interval[[:space:]]/{print $2; exit}' "$COLLECTD_CONF")
DEFAULT_INTERVAL="${DEFAULT_INTERVAL:-60}"

# Parse rrdtool plugin settings
eval $(awk '
	/<Plugin rrdtool>/ { in_block=1 }
	/<\/Plugin>/       { in_block=0 }
	in_block && /RRASingle[[:space:]]+true/  { single=1 }
	in_block && /RRATimespan[[:space:]]/     { count++; timespans[count]=$2 }
	in_block && /RRARows[[:space:]]/         { rows=$2 }
	in_block && /XFF[[:space:]]/             { xff=$2 }
	END {
		printf "RRDTOOL_RRA_SINGLE=%d\n", single
		printf "RRDTOOL_ROWS=%d\n",   (rows ? rows : 60)
		printf "RRDTOOL_XFF=%s\n",        (xff  ? xff  : "0.1")
		printf "RRDTOOL_RRA_COUNT=%d\n",  (single ? count : count * 3)
		for (i=1; i<=count; i++)
			printf "RRDTOOL_TIMESPAN_%d=%d\n", i, timespans[i]
		printf "RRDTOOL_TIMESPAN_COUNT=%d\n", count
	}
' "$COLLECTD_CONF")

get_interval() {
	local plugin="$1"
	awk -v p="$plugin" '
		/<LoadPlugin[[:space:]]/ {
			if ($0 ~ "<LoadPlugin[[:space:]]+"p"[[:space:]]*>") found=1
		}
		found && /Interval/ { print $2; found=0; exit }
		/<\/LoadPlugin>/ { found=0 }
	' "$COLLECTD_CONF"
}

# Compute expected pdp_per_row for each RRATimespan given a step
# Returns space-separated list of pdp_per_row values (one per timespan)
expected_pdp_per_rows() {
	local step="$1"
	local i pdp result="" seen=""
	i=1
	while [ "$i" -le "$RRDTOOL_TIMESPAN_COUNT" ]; do
		eval "ts=\$RRDTOOL_TIMESPAN_${i}"
		pdp=$(( ts / (RRDTOOL_ROWS * step) ))
		[ "$pdp" -lt 1 ] && pdp=1
		# skip duplicate pdp_per_row values
		echo "$seen" | grep -qw "$pdp" || {
			result="$result $pdp"
			seen="$seen $pdp"
		}
		i=$((i + 1))
	done
	echo "$result"
}

# Count of unique expected RRAs (after deduplication)
expected_rra_count() {
	local step="$1"
	expected_pdp_per_rows "$step" | wc -w | tr -d ' '
}

check_space() {
	local rrd="$1"
	local dir
	dir=$(dirname "$rrd")
	local rrd_size avail
	rrd_size=$(du -k "$rrd" 2>/dev/null | awk '{print $1}')
	avail=$(df -k "$dir" 2>/dev/null | awk 'NR==2{print $4}')
	if [ -n "$rrd_size" ] && [ -n "$avail" ] && [ "$avail" -lt $((rrd_size * 2)) ]; then
		logger -t rrd-tune "ERROR: not enough space in $dir (need $((rrd_size * 2))k, have ${avail}k)"
		echo "ERROR: not enough space in $dir to fix $rrd (need $((rrd_size * 2))k, have ${avail}k)" >&2
		return 1
	fi
}

# Fix step, RRA count, pdp_per_row and rows via dump/restore
fix_via_dump() {
	local rrd="$1"
	local new_step="$2"      # 0 = don't change step
	local fix_rras="$3"      # 1 = fix RRA structure

	check_space "$rrd"

	local dir base tmp
	dir=$(dirname "$rrd")
	base=$(basename "$rrd")
	tmp="$dir/.${base}"
	local tmp_xml="${tmp}.xml"
	local tmp_rrd="${tmp}.new"

	rrdtool dump "$rrd" > "$tmp_xml"

	# Fix step if needed
	if [ "$new_step" -gt 0 ]; then
		sed -i "s|<step>[[:space:]]*[0-9]*[[:space:]]*</step>|<step> $new_step </step>|" "$tmp_xml"
	fi

	# Fix RRA structure if needed — deduplicate by pdp_per_row keeping last occurrence,
	# then fix pdp_per_row values and rows count per expected config
	if [ "$fix_rras" -eq 1 ]; then
		local rrd_info step ds_count
		rrd_info=$(rrdtool info "$rrd")
		step=$(echo "$rrd_info" | awk -F' = ' '/^step /{print int($2+0); exit}')
		[ "$new_step" -gt 0 ] && step="$new_step"
		ds_count=$(awk '/<rra>/{exit} /<ds>/{n++} END{print n+0}' "$tmp_xml")
		[ -z "$ds_count" ] && ds_count=0
		[ "$ds_count" -lt 1 ] && ds_count=1

		local pdp_list
		pdp_list=$(expected_pdp_per_rows "$step")

		awk -v pdp_list="$pdp_list" \
		    -v rows="$RRDTOOL_ROWS" \
		    -v xff="$RRDTOOL_XFF" \
		    -v step="$step" \
		    -v ds_count="$ds_count" '
			/<rra>$/     { in_rra=1; block=$0 "\n"; next }
			in_rra       { block = block $0 "\n" }
			in_rra && /<\/rra>$/ {
				in_rra=0
				n = split(block, lines, "\n")
				pdp=""
				for (i=1; i<=n; i++) {
					if (lines[i] ~ /<pdp_per_row>/) {
						match(lines[i], /[0-9]+/)
						pdp = substr(lines[i], RSTART, RLENGTH)
						break
					}
				}
				rra_count++
				rra_block[rra_count] = block
				rra_pdp[rra_count]   = pdp + 0
				last_of_pdp[pdp]     = rra_count
				# parse timestamps and values from data rows
				in_db=0
				for (i=1; i<=n; i++) {
					if (lines[i] ~ /<database>/)    { in_db=1; continue }
					if (lines[i] ~ /<\/database>/) { in_db=0; continue }
					if (!in_db) continue
					if (match(lines[i], /[0-9]{9,}/) > 0)
						ts = substr(lines[i], RSTART, RLENGTH) + 0
					if (match(lines[i], /<v>[^<]*<\/v>/) > 0) {
						v = substr(lines[i], RSTART+3, RLENGTH-7)
						gsub(/[[:space:]]/, "", v)
						data[rra_count, ts] = v
					}
				}
				next
			}
			in_rra { next }

			function resample(target_ts,    best, best_dist, rc, period, slot_ts, v, dist) {
				best = "NaN"; best_dist = -1
				for (rc=1; rc<=rra_count; rc++) {
					period   = step * rra_pdp[rc]
					slot_ts  = int(target_ts / period) * period
					v = data[rc, slot_ts]
					if (v == "" || v == "NaN") continue
					dist = (target_ts >= slot_ts) ? (target_ts - slot_ts) : (slot_ts - target_ts)
					if (best_dist < 0 || dist < best_dist) {
						best_dist = dist; best = v
					}
				}
				return best
			}

			function make_rra(ep, lu,    period, slot0, i, d, ts, v, row, out) {
				period = step * ep
				slot0  = int(lu / period) * period - (rows - 1) * period
				out    = "\t<rra>\n"
				out    = out "\t\t<cf> AVERAGE </cf>\n"
				out    = out "\t\t<pdp_per_row> " ep " </pdp_per_row> <!-- " period " seconds -->\n"
				out    = out "\t\t<xff> " xff " </xff>\n\n"
				out    = out "\t\t<cdp_prep>\n"
				for (d=0; d<ds_count; d++)
					out = out "\t\t\t<ds><value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n"
				out    = out "\t\t</cdp_prep>\n"
				out    = out "\t\t<database>\n"
				for (i=0; i<rows; i++) {
					ts  = slot0 + i * period
					v   = resample(ts)
					row = "<row>"
					for (d=0; d<ds_count; d++) row = row "<v> " v " </v>"
					out = out "\t\t\t<!-- " ts " --> " row "</row>\n"
				}
				out = out "\t\t</database>\n\t</rra>\n"
				return out
			}

			# helper: check if an rra block is all NaN
			function rra_all_nan(rc,    ts, k) {
				for (k in data) {
					split(k, kp, SUBSEP)
					if (kp[1]+0 == rc && data[k] != "NaN" && data[k] != "")
						return 0
				}
				return 1
			}

			# helper: rebuild an existing rra block with backfilled+trimmed/expanded rows
			function rebuild_rra(b, ep, lu,    nb, blines, bi, nrow, skip, add,
			                     in_db2, out, db_lines, period, slot0, i, j, ts, v) {
				gsub(/<pdp_per_row>[^<]*<\/pdp_per_row>/, 					"<pdp_per_row> " ep " </pdp_per_row>", b)
				gsub(/<xff>[^<]*<\/xff>/, 					"<xff> " xff " </xff>", b)
				nb = split(b, blines, "\n")
				nrow = 0
				for (bi=1; bi<=nb; bi++)
					if (blines[bi] ~ /<row>/) nrow++
				period = step * ep
				slot0  = int(lu / period) * period - (rows - 1) * period
				# build header (everything before <database>)
				out = ""; db_lines = ""; in_db2 = 0
				skip = (nrow > rows) ? (nrow - rows) : 0
				add  = (rows > nrow) ? (rows - nrow) : 0
				i = 0
				for (bi=1; bi<=nb; bi++) {
					if (blines[bi] ~ /<database>/) {
						in_db2=1
						# prepend synthetic rows for expansion before existing rows
						db_lines = db_lines blines[bi] "\n"
						for (j=0; j<add; j++) {
							ts  = slot0 + j * period
							v   = resample(ts)
							row = "<row>"
							for (d=0; d<ds_count; d++) row = row "<v> " v " </v>"
							db_lines = db_lines "\t\t\t<!-- " ts " --> " row "</row>\n"
						}
						continue
					}
					if (blines[bi] ~ /<\/database>/) { in_db2=0; db_lines=db_lines blines[bi] "\n"; continue }
					if (in_db2 && blines[bi] ~ /<row>/) {
						if (skip > 0) { skip--; continue }
						# backfill NaN slots from other RRAs
						ts = slot0 + (add + i) * period
						v = resample(ts)
						if (blines[bi] ~ /<v> NaN <\/v>/ && v != "NaN")
							gsub(/<v> NaN <\/v>/, "<v> " v " </v>", blines[bi])
						# pad missing <v> tags for corrupt rows (wrong DS count)
						tmp_line = blines[bi]
						actual_v = gsub(/<v>/, "", tmp_line)
						if (actual_v < ds_count) {
							# rebuild row with correct ds_count <v> tags
							row = "<row>"
							for (d=0; d<ds_count; d++) row = row "<v> " v " </v>"
							sub(/<row>.*<\/row>/, row "</row>", blines[bi])
						}
						db_lines = db_lines blines[bi] "\n"
						i++
						continue
					}
					if (!in_db2 && blines[bi] !~ /<\/rra>/ && blines[bi] != "") out = out blines[bi] "\n"
				}
				return out db_lines "\t</rra>\n"
			}

			# Register data from a block string into data[] under a given rc index
			function register_block_data(rc, blk,    nb, blines, bi, ts, v) {
				nb = split(blk, blines, "\n")
				for (bi=1; bi<=nb; bi++) {
					if (match(blines[bi], /[0-9]{9,}/) > 0)
						ts = substr(blines[bi], RSTART, RLENGTH) + 0
					if (match(blines[bi], /<v>([^<]+)<\/v>/) > 0) {
						v = substr(blines[bi], RSTART+3, RLENGTH-7)
						gsub(/[[:space:]]/, "", v)
						data[rc, ts] = v
					}
				}
			}

			# Synthesize blocks for all missing pdp_per_row values;
			# register their data so resample() can use them in the emit pass
			function synthesize_missing(np, expected_pdp, lu,    ei, ep, synth_rc, blk) {
				for (ei=1; ei<=np; ei++) {
					ep = expected_pdp[ei]
					if (ep in last_of_pdp) continue
					blk = make_rra(ep, lu)
					synth_rc = rra_count + ei
					rra_pdp[synth_rc] = ep
					register_block_data(synth_rc, blk)
					synth_block[ei] = blk
				}
			}

			# Emit all expected RRAs: rebuild existing ones (backfill + trim),
			# or emit pre-synthesized blocks for missing ones
			function emit_rras(np, expected_pdp, lu,    ei, ep) {
				for (ei=1; ei<=np; ei++) {
					ep = expected_pdp[ei]
					if (ep in last_of_pdp)
						printf "%s", rebuild_rra(rra_block[last_of_pdp[ep]], ep, lu)
					else
						printf "%s", synth_block[ei]
				}
			}

			/<\/rrd>$/ {
				np = split(pdp_list, expected_pdp)
				synthesize_missing(np, expected_pdp, lastupdate)
				emit_rras(np, expected_pdp, lastupdate)
				print; next
			}
			/lastupdate/ {
				match($0, /[0-9]{9,}/)
				lastupdate = substr($0, RSTART, RLENGTH) + 0
				print; next
			}
			{ print }
		' "$tmp_xml" > "${tmp}.fixed.xml"

		mv "${tmp}.fixed.xml" "$tmp_xml"
	fi

	if ! rrdtool restore "$tmp_xml" "$tmp_rrd" 2>/tmp/rrd_restore_err; then
		echo "restore failed for $rrd:" >&2
		cat /tmp/rrd_restore_err >&2
		cat "$tmp_xml" >&2
		rm -f "$tmp_xml" "$tmp_rrd"
		return 1
	fi
	rm /tmp/rrd_restore_err
	mv "$tmp_rrd" "$rrd"
	rm -f "$tmp_xml"
}

found_mismatch=0
rrd_list=$(mktemp /tmp/rrd-tune.XXXXXX) || exit 1
trap 'rm -f "$rrd_list"' EXIT INT TERM

find "$RRD_BASE" -name "*.rrd" | sort > "$rrd_list"

while IFS= read -r rrd; do
	plugin_dir=$(basename "$(dirname "$rrd")")
	plugin="${plugin_dir%%-*}"

	interval=$(get_interval "$plugin")
	interval="${interval:-$DEFAULT_INTERVAL}"
	heartbeat=$(( (interval * 101 + 99) / 100 ))  # 1.01x interval, rounded up

	info=$(rrdtool info "$rrd" 2>/dev/null)
	[ -z "$info" ] && continue

	current_step=$(echo "$info"     | awk -F' = ' '/^step /{print int($2+0); exit}')
	# Check if ANY DS has wrong heartbeat (not just first)
	current_hb=$(echo "$info" | awk -F' = ' -v hb="$heartbeat" '
		/^ds\[[^]]*\]\.minimal_heartbeat/ {
			val = int($2+0)
			count++
			if (count == 1 || val < min) min = val
			if (val != hb) mismatch = val
		}
		END { print (mismatch ? mismatch : min) }
	' 2>/dev/null)
	current_rra_count=$(echo "$info" | sed -n 's/^rra\[\([0-9]\+\)\].*/\1/p' | sort -n | tail -1)
	current_rra_count="$((${current_rra_count:-0}+1))"

	[ -z "$current_step" ] || [ -z "$current_hb" ] && continue

	step_ok=1
	hb_ok=1
	[ "$current_step" -ne "$interval" ] && step_ok=0
	[ "$current_hb"   -ne "$heartbeat" ] && hb_ok=0

	# Expected pdp_per_row and rows for each RRA given the configured interval.
	# The RRD step is expected to match the plugin interval exactly.
	expected_pdps=$(expected_pdp_per_rows "$interval")

	# Check each RRA's pdp_per_row, rows, xff — only when RRA count matches
	pdp_ok=1
	rows_ok=1
	xff_ok=1
	nan_ok=1
	expected_xff_i=$(echo "$RRDTOOL_XFF" | awk '{printf "%d", $1*1000}')
	if [ "$current_rra_count" -eq "$RRDTOOL_RRA_COUNT" ]; then
		i=0
		for ep in $expected_pdps; do
			current_pdp=$(echo "$info"  | awk -F' = ' "/^rra\[$i\]\.pdp_per_row/{print int(\$2+0); exit}")
			current_rows=$(echo "$info" | awk -F' = ' "/^rra\[$i\]\.rows/{print int(\$2+0); exit}")
			current_xff=$(echo "$info"  | awk -F' = ' "/^rra\[$i\]\.xff/{print \$2+0; exit}")
			[ "$current_pdp"  != "$ep" ]             && pdp_ok=0
			[ "$current_rows" != "$RRDTOOL_ROWS" ]   && rows_ok=0
			current_xff_i=$(echo "$current_xff" | awk '{printf "%d", $1*1000}')
			[ "$current_xff_i" != "$expected_xff_i" ] && xff_ok=0
			i=$((i + 1))
		done
	fi
	# Check if any RRA has NaN slots that other RRAs could fill — detect via rrdtool dump
	# Compute expected RRA count for the configured interval
	# (deduplicating identical pdp_per_row values)
	expected_rra_count=$(expected_pdp_per_rows "$interval" | wc -w | tr -d ' ')
	# Compute rra_ok before nan_ok check which depends on it
	rra_ok=1
	[ "$expected_rra_count" -gt 0 ] && \
		[ "$current_rra_count" -ne "$expected_rra_count" ] && rra_ok=0

	if [ "$step_ok" -eq 1 ] && [ "$pdp_ok" -eq 1 ] && [ "$rows_ok" -eq 1 ] && [ "$rra_ok" -eq 1 ]; then
		nan_ok=$(rrdtool dump "$rrd" 2>/dev/null | awk -v step="$current_step" '
			/lastupdate/ { match($0, /[0-9]{9,}/); lastupdate = substr($0, RSTART, RLENGTH) + 0 }
			/<rra>$/     { in_rra=1; block=""; next }
			in_rra       { block = block $0 "\n" }
			in_rra && /<\/rra>$/ {
				in_rra=0
				# extract pdp and data
				n = split(block, lines, "\n")
				pdp=1
				for (i=1; i<=n; i++) {
					if (lines[i] ~ /<pdp_per_row>/) {
						match(lines[i], /[0-9]+/); pdp=substr(lines[i],RSTART,RLENGTH)+0; break
					}
				}
				rra_count++; rra_pdp[rra_count]=pdp
				in_db=0
				for (i=1; i<=n; i++) {
					if (lines[i] ~ /<database>/)    { in_db=1; continue }
					if (lines[i] ~ /<\/database>/) { in_db=0; continue }
					if (!in_db) continue
					if (match(lines[i], /[0-9]{9,}/) > 0) ts=substr(lines[i],RSTART,RLENGTH)+0
					if (match(lines[i], /<v>([^<]+)<\/v>/) > 0) {
						v=substr(lines[i],RSTART+3,RLENGTH-7); gsub(/[[:space:]]/, "", v)
						if (v != "NaN") has_data[rra_count,ts]=v
						else            nan_slots[rra_count,ts]=1
					}
				}
				next
			}
			END {
				# for each NaN slot, check if any other RRA has data near that timestamp
				# only consider slots older than 3x the step to avoid flagging recent gaps
				# that are simply collectd not having collected yet
				for (k in nan_slots) {
					split(k, kp, SUBSEP); rc=kp[1]+0; ts=kp[2]+0
					if (ts > lastupdate - step * rra_pdp[rc] * 3) continue
					for (rc2=1; rc2<=rra_count; rc2++) {
						if (rc2 == rc) continue
						period2 = step * rra_pdp[rc2]
						slot2   = int(ts / period2) * period2
						if ((rc2, slot2) in has_data) { print 0; exit }
					}
				}
				print 1
			}
		' 2>/dev/null)
		[ -z "$nan_ok" ] && nan_ok=1
	fi

	# Check if any rows have wrong number of <v> tags (corrupt multi-DS RRD)
	ds_v_ok=1
	if [ "$rra_ok" -eq 1 ] && [ "$pdp_ok" -eq 1 ]; then
		ds_expected=$(rrdtool dump "$rrd" 2>/dev/null | awk '/<rra>/{exit} /<ds>/{n++} END{print n+0}')
		if [ "${ds_expected:-1}" -gt 1 ]; then
			bad=$(rrdtool dump "$rrd" 2>/dev/null | awk -v n="$ds_expected" '
				/<row>/ {
					count = 0
					s = $0
					while (match(s, /<v>/)) { count++; s = substr(s, RSTART+3) }
					if (count != n+0) { print 1; exit }
				}
			' 2>/dev/null)
			[ "${bad:-0}" -eq 1 ] && ds_v_ok=0
		fi
	fi

	needs_dump=0
	[ "$step_ok"  -eq 0 ] && needs_dump=1
	[ "$rra_ok"   -eq 0 ] && needs_dump=1
	[ "$pdp_ok"   -eq 0 ] && needs_dump=1
	[ "$rows_ok"  -eq 0 ] && needs_dump=1
	[ "$xff_ok"   -eq 0 ] && needs_dump=1
	[ "$nan_ok"   -eq 0 ] && needs_dump=1
	[ "$ds_v_ok"  -eq 0 ] && needs_dump=1

	all_ok=1
	[ "$step_ok" -eq 0 ] || [ "$hb_ok"   -eq 0 ] || [ "$rra_ok"  -eq 0 ] || \
	[ "$pdp_ok"  -eq 0 ] || [ "$rows_ok" -eq 0 ] || [ "$xff_ok"  -eq 0 ] || \
	[ "$nan_ok"  -eq 0 ] || [ "$ds_v_ok" -eq 0 ] && all_ok=0

	[ "$all_ok" -eq 1 ] && continue

	case "$OP" in
	fix)
		new_step=0
		fix_rras=0
		if [ "$step_ok" -eq 0 ]; then
			logger -t rrd-tune "$rrd: step $current_step -> $interval"
			new_step="$interval"
		fi
		if [ "$rra_ok" -eq 0 ] || [ "$pdp_ok" -eq 0 ] || \
		   [ "$rows_ok" -eq 0 ] || [ "$xff_ok" -eq 0 ] || \
		   [ "$nan_ok"  -eq 0 ] || [ "$ds_v_ok" -eq 0 ]; then
			logger -t rrd-tune "$rrd: fixing RRA structure"
			fix_rras=1
		fi
		if [ "$needs_dump" -eq 1 ]; then
			fix_via_dump "$rrd" "$new_step" "$fix_rras"
		fi
		if [ "$hb_ok" -eq 0 ]; then
			logger -t rrd-tune "$rrd: heartbeat $current_hb -> $heartbeat (interval=${interval}s)"
			# tune heartbeat for all DS in this RRD
			ds_names=$(echo "$info" | sed -n 's/^ds\[\([^]]*\)\].*/\1/p' | sort -u)
			for ds_name in $ds_names; do
				rrdtool tune "$rrd" --heartbeat "${ds_name}:${heartbeat}"
			done
		fi
		;;
	report)
		echo "MISMATCH: $rrd"
		echo "  plugin=$plugin  interval=${interval}s"
		[ "$step_ok"  -eq 0 ] && \
			echo "  step:        interval=${interval}s  rrd=${current_step}s"
		[ "$hb_ok"    -eq 0 ] && \
			echo "  heartbeat:   configured=${heartbeat}s  rrd=${current_hb}s"
		[ "$rra_ok"   -eq 0 ] && \
			echo "  rra count:   configured=${expected_rra_count}  rrd=${current_rra_count}"
		[ "$pdp_ok"   -eq 0 ] && \
			echo "  pdp_per_row: configured=$(echo $expected_pdps)  rrd mismatch"
		[ "$rows_ok"  -eq 0 ] && \
			echo "  rows:        configured=${RRDTOOL_ROWS}  rrd=${current_rows}"
		[ "$xff_ok"   -eq 0 ] && \
			echo "  xff:         configured=${RRDTOOL_XFF}  rrd=${current_xff}"
		[ "$nan_ok"   -eq 0 ] && \
			echo "  nan slots:   backfillable from other RRAs"
		[ "$ds_v_ok"  -eq 0 ] && \
			echo "  corrupt rows: wrong DS count in row <v> tags"
		found_mismatch=1
		;;
	esac
done < "$rrd_list"

[ "$OP" = "report" ] && [ "$found_mismatch" -eq 1 ] && exit 1
exit 0

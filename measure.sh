#!/bin/sh
# Runs a command, then prints its elapsed time and the peak memory in use on
# the whole runner (MemTotal - MemAvailable, sampled every 0.2 s).
memory=$(mktemp)
(while :; do awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {print t-$2}' /proc/meminfo; sleep 0.2; done) > "$memory" &
sampler=$!
start=$(date +%s.%N)
"$@"
status=$?
end=$(date +%s.%N)
kill "$sampler"
total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
echo "MEASURE $*: exit $status, $(awk -v a="$start" -v b="$end" 'BEGIN {printf "%.1f", b - a}') s, memory in use before $(( $(head -n 1 "$memory") / 1024 )) MiB, peak $(( $(sort -n "$memory" | tail -n 1) / 1024 )) MiB of $(( total / 1024 )) MiB"
exit "$status"
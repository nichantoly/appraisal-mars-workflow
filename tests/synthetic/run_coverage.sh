#!/bin/bash
# Known-answer test behind the coverage figures in the README: 16 synthetic markets (seeds 101 to 116, 420 sales each,
# price paths A to D in turn) with realtor-style listing errors, then the browser engine with the weights on and off.
set -e
cd "$(dirname "$0")"
mkdir -p reps23
for s in $(seq 101 116); do
  p=$(echo ABCD | cut -c$(( (s - 101) % 4 + 1 )))
  python3 gen23.py $s 420 $p reps23/sales_$s.csv reps23/truth_$s.json > /dev/null
done
node coverage23.js on
node coverage23.js off

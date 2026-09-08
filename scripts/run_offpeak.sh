#!/usr/bin/env bash
# Off-peak guard for DeepSeek pricing. Exits 0 (off-peak → run your job) or 1 (peak → skip).
# Peak = Mon-Fri 01:00-04:00 UTC and 06:00-10:00 UTC (2x price); everything else = half price.
# PT translation: peak ≈ 6-9pm & 11pm-3am; off-peak = 9-11pm & 3am-6pm.
# Usage:  30 14 * * 1-5  /home/chad/localsetup/scripts/run_offpeak.sh \
#                        && /home/chad/localsetup/.venv/bin/python \
#                           /home/chad/localsetup/scripts/batch_job.py jobs.jsonl
set -euo pipefail
H=$(date -u +%H)
DOW=$(date -u +%u)   # 1=Mon .. 7=Sun

is_peak=0
if [ "$DOW" -le 5 ]; then
  if { [ "$H" -ge 1 ] && [ "$H" -lt 4 ]; } || { [ "$H" -ge 6 ] && [ "$H" -lt 10 ]; }; then
    is_peak=1
  fi
fi

if [ "$is_peak" -eq 1 ]; then
  echo "PEAK hours (UTC ${H}:00, Mon-Fri) — DeepSeek at 2x. Skipping job." >&2
  exit 1
fi
echo "off-peak (UTC ${H}:00) — half price. Running."
exit 0

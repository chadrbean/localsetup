# Off-Peak Windows, Batch, and Caching

Date-stamped: **Aug 31, 2026**. DeepSeek changed its pricing model on **Aug 16, 2026** —
the old "16:30-00:30 UTC" discount window is retired. Re-verify monthly at
api-docs.deepseek.com.

## DeepSeek peak / off-peak (current)

- **Peak (2x rate):** Mon-Fri 01:00-04:00 UTC and 06:00-10:00 UTC (7h/day).
- **Off-peak (half rate):** all other hours + all weekend.
- **Pacific (PDT/PST) translation:**
  - Peak = **6-9pm PT** and **11pm-3am PT** (Mon-Fri).
  - Off-peak = **9-11pm PT** and **3am-6pm PT** (Mon-Fri) + all day weekends.
  - i.e. the US working day is naturally off-peak — no effort needed for daytime work.

## Scheduling rules for repetitive/batch work

1. Run bulk jobs outside the two peak windows. In Pacific time: peak = 6-9pm PT and
   11pm-3am PT; off-peak = 9-11pm PT and 3am-6pm PT. US working hours are off-peak.
2. Guard every cron job with `scripts/run_offpeak.sh` so it can't accidentally fire
   during peak: `run_offpeak.sh && batch_job.py jobs.jsonl`.
3. Keep the system prompt prefix byte-identical across runs → DeepSeek server-side
   prompt cache hits at ~$0.0028/M input (~50x cheaper than cache-miss).
4. Batch APIs (OpenAI / Gemini / Anthropic) give a flat 50% off for async jobs with
   up-to-24h turnaround. DeepSeek's equivalent lever is off-peak + cache, not a batch
   endpoint.
5. Stacked example: a repetitive extraction job off-peak with a cached prompt on Flash
   ≈ $0.003/M effective input — a 10-50x saving over naive peak-time uncached use.

## Tools

- `scripts/batch_job.py` — queue worker: stable system prompt + flash + automation key.
- `scripts/run_offpeak.sh` — cron guard (exit 0 = off-peak, run; exit 1 = peak, skip).
- `scripts/cost_report.py` — flags peak-hour spend so drift is visible.

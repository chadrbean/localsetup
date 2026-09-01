# Router Evaluation Notes

Date: 2026-08-31. Decision: **keep RouteLLM/bert** — no change.

## Candidates evaluated

### xrouter-llm (xorbitsai, github.com/xorbitsai/xrouter-llm)
- What: prompt-aware routing-DECISION service (IRT-style: capability(model) x
  difficulty(prompt) -> predicted completion, picks cheapest capable model).
  Does NOT call LLMs; ships a trained artifact + model registry; `pip install xrouter-llm`.
- Interesting bits: multi-model (kills RouteLLM's binary limit); native
  `utc_price_overrides` per-model (time-of-day pricing — matches DeepSeek
  peak/off-peak); capability from published benchmarks.
- Why NOT adopted:
  1. Difficulty model trained on coding/math/terminal — our task mix (browser
     automation, docs, taxes/accounting) is exactly the gap the README admits;
     would need fine-tuning on our own traffic to be accurate.
  2. Decision-only: needs a glue shim (or 2-hop client) to be OpenAI-compatible.
  3. No cache-hit pricing in profiles (our biggest repetitive-task lever).
  4. Extra runtime: server + 0.6B embedding model on CPU + SQLite log.
  5. License: Xagent Source License (source-available, not OSI).
  6. Marginal gain for a deliberate 3-model spine; the two big cost levers
     (off-peak scheduling, prompt caching) live in the gateway, not the router.
- Revisit if: spine grows to many providers, or eval shows hard tasks frequently
  routed to flash, or we fine-tune a router on real traffic.

### xRouter (Salesforce AI Research, arXiv 2510.08439)
- RL-trained agentic orchestrator; needs GPU (torch+flash-attn+vLLM, hosts its own
  router model), no gateway features, research code. Rejected — infra mismatch.

### Salesforce/UIUC LLMRouter + xRouteBench (Aug 2026)
- Academic framework/benchmark for building routers. Not a drop-in service.

## Why the current router stays
- BERT router (routellm/bert_gpt4_augmented, threshold 0.44878) is local,
  deterministic, ~free per request, no GPU.
- LiteLLM provides the load-bearing features (keys, budgets, spend, fallback,
  off-peak scheduling) — router choice doesn't affect them.
- Router layer is disposable: swapping = one config + one endpoint, nothing else moves.

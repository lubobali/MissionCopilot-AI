# Spike #13: constrained structured output

Status: **GO**. Engine: MLX 3.32.3 with `MLXGuidedGeneration` (XGrammar), LFM2.5 1.2B 4-bit, iPhone 13 Pro Max,
airplane mode. Raw data in results/bench-structured-*.json.

## Setup
- JSON Schema with 8 required fields (invoice number, date, amount due, cumulative paid, contract value,
  km completed, km total, bridge status enum), `additionalProperties: false`, integers for money.
- **Constrained:** grammar compiled from the schema; the loop is greedy (argmax), so output is deterministic.
- **Free:** same prompt plus the schema as text, sampled (temperature 0.1, seeds 1-20).
- **Code, not the model,** parses the JSON, checks every field against the true values, computes financial
  and physical progress, and raises MC-01 when the gap is above 20 points (ADR 0005, ADR 0010).

## Results (20 runs each)
| | Constrained + code | Free text |
|---|---|---|
| Valid JSON for the schema | **20/20** | 0/20 |
| All 8 fields correct | **20/20** | 0/20 |
| MC-01 raised (85% paid vs 50% built) | **20/20** | 0/20 |
| Time per extraction | **3.1 s** (every run) | 6.0 s median, up to 53.5 s |
| Phone thermal state | nominal / fair | fair / **serious** |

Free text copied the schema's shape instead of answering and invented values (amount due 800,000).

## The failure we had to fix (diagnosed, not guessed)
The first constrained run failed 20/20 with `incompleteOutput`. Saving the partial output showed **7 of 7 values
already correct**, then the greedy loop emitted tab characters between fields until the 256-token limit (JSON
allows unlimited whitespace). Fix: the library's `WhitespaceTokenBias` (penalizes runs of whitespace-only
tokens). After the fix: 20/20.

Lesson: when a constrained run fails, keep the partial output. The diagnosis took one run.

## Also learned
- **Thermal state matters:** free generation pushed the phone to "serious". Short, constrained outputs keep it
  cool. Production must watch `ProcessInfo.thermalState` and back off.
- **Reproducibility:** the guided loop is deterministic by design; for free-text writing, a fixed seed gives
  repeatable output (ADR 0004 follow-up).

## Decision
- **Constrained output is required for every fact the app extracts.** Free-text JSON is never parsed for facts.
- **MLX confirmed as the engine** (ADR 0004): runtime JSON-schema constraints worked on the device.

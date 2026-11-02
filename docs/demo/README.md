# Demo dataset: Kandor Rural Roads Project (fictional)

`kandor-rural-roads.json` is fully invented. Kandor is not a real country. The tests in
`backend/tests/unit/test_demo_dataset.py` keep the story intact: if an edit breaks a planted risk,
CI fails.

## The story
A field officer arrives for a five-day supervision mission on a 64 km rural road. The contractor
has been paid 85% of the contract, but only half the road is built, the bridge on Section 3 has not
started, and at km 18 the road is narrower than specified.

## Demo moments and their data

| Demo moment | Data used | Expected result |
|---|---|---|
| Prepare online, then go offline | `mission`, `pack` | Mission pack downloaded; "Ready for offline" |
| "What was promised last mission?" | `pack.lastReportSummary` | Answer with its source: bridge start by July, revised work plan |
| Scan invoice 14 | `documents[invoice]` | Facts: invoice 14, $480,000, cumulative $8.5M of $10M |
| Scan the progress report | `documents[progress_report]` | Facts: 32 of 64 km built, bridge not started |
| Payment ahead of progress | `pack.payments`, `pack.physicalProgress` | **MC-01 raised**: 85% paid vs 50% built (35 points) |
| Late milestone | `pack.milestones` | **R067 raised**: Section 3 bridge past due, not met |
| Payments within contract | `pack.payments`, `pack.contractValue` | **R068 clear** ($8.5M ≤ $10M) |
| Guided site inspection | `pack.checklist` | Checklist questions; road width measured |
| Ground finding | `fieldFindings.roadWidth` | Road about 30% narrower than specified at km 18 |
| Ministry letter in French | `documents[letter]` | Note: extension to 15 March 2027 if a new work plan arrives in two weeks |
| Report and approval | all facts above | Every sentence linked to facts; untraceable sentences blocked |

## Prompt-injection test set (story #48)
`injection/` holds 30 attacks built from this dataset, plus a clean copy of each source (invoice,
progress report, spoken debrief). `answer-key.json` says what each attack wants (field, attacker's
value, true value) and which defense should stop it, so results are scored by code. Families: visible
instructions, hidden text (near-white, tiny, light gray), fake second values and changed table rows,
fake approvals, dates outside the contract period (`pack.contractPeriod`), spoken instructions (stock
macOS voice, never a real person's) and one oversized input. Payments are approved only in the app,
by `pack.paymentApprover`, never by anything printed on a document.
Rebuild: `uv run --directory backend python ../scripts/make_injection_set.py`.

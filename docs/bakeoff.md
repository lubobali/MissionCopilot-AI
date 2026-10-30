# Step 0.0: Model bake-off on iPhone 13 Pro Max

Date: Oct 30 2026. Phone: iPhone 13 Pro Max, iOS 27.2, AIRPLANE MODE ON.
Fictional project only (synthetic data).

## How to run
1. Turn on airplane mode.
2. Open the app, pick the model, start a NEW chat for every test.
3. Paste the test text, send.
4. Write down: tokens/sec, seconds until the first word, crash or slow, phone warm?,
   quality 1-5.
5. Same tests for every model.

## T1: Debrief to notes (English)
```
Turn this voice debrief into mission notes with 3 sections: DECISIONS, ACTION ITEMS (who, what, by when), RISKS. Be short. Use only facts from the text.

Debrief: ok so just met the deputy minister of transport, Mr. Okafor, and the road agency director. they agreed to extend the contractor deadline to march 15 but only if the contractor shows a new work plan in two weeks. the contractor is about 3 months late, they say the rains and fuel shortages. section 3 bridge still not started. the minister asked the bank to send an engineer in january. also the payments look high compared to what we saw on the road, need to check invoice 14. procurement for the second package is stuck, waiting for the no-objection from our side. I promised to send the no-objection by friday.
```

## T1-FR: same in French
```
Transforme ce compte rendu en notes de mission avec 3 sections en anglais : DECISIONS, ACTION ITEMS (qui, quoi, quand), RISKS. Sois court.

Compte rendu : réunion avec le vice-ministre des transports, M. Okafor, et le directeur de l'agence routière. Ils acceptent de prolonger le délai de l'entreprise jusqu'au 15 mars, à condition qu'elle présente un nouveau plan de travail dans deux semaines. L'entreprise a environ trois mois de retard à cause des pluies et des pénuries de carburant. Le pont de la section 3 n'est pas commencé. Le ministre demande à la Banque d'envoyer un ingénieur en janvier. Les paiements semblent élevés par rapport aux travaux réalisés, il faut vérifier la facture 14.
```

## T2: Extract facts
```
Extract the facts from these two documents as a list: invoice number, amount, total paid so far, total budget, percent of budget paid, percent of road built, dates. Then say in one line if there is a risk and why. Use only numbers from the text.

INVOICE No. 14 - Kandor Rural Roads Project, Package 1. Date: 12 Oct 2026. Contractor: Sahel Build Ltd. Amount due: USD 480,000. Cumulative paid including this invoice: USD 8,500,000. Contract value: USD 10,000,000.

CONTRACTOR PROGRESS REPORT, September 2026. Road section 1 to 3, total length 64 km. Completed: 32 km asphalt. Section 3 bridge: not started. Planned completion: 15 Dec 2026.
```

## T3: Draft one report paragraph
```
Write one short paragraph for a development-finance mission report (Aide-Memoire style), section "Implementation Progress", formal and neutral tone, using only these facts:
- Contractor about 3 months behind schedule (rains, fuel shortages)
- 32 of 64 km built (50%), bridge at section 3 not started
- 85% of the contract value paid (USD 8.5M of 10M)
- Government agreed to extend the deadline to 15 March 2027 if a new work plan is submitted within two weeks
- The mission recommends a technical audit of invoice 14
```

## Results

| Model | App | T1 tok/s | T1 quality | T1-FR quality | T2 quality | T3 quality | First word (s) | Crash/slow | Warm? |
|---|---|---|---|---|---|---|---|---|---|
| LFM2.5 1.2B | PocketPal | 38.2 | 3 | 3 | 1 (invoice $8.5M wrong, missed 85% vs 50% risk) | 4 | 0.6-2.7 | no | ? |
| Gemma 3 1B | PocketPal | | | | | | | | |
| Qwen3 1.7B | PocketPal | 13-21 | 2.5 (named Okafor, answers cut off) | 2 (made up 14 Feb, 15 Mar) | ? ($480K right, cut off) | ? (cut off) | 0.16-2.9 | answers cut off (max tokens setting?) | ? |
| SmolLM3 3B | PocketPal | 13.7 | 2 (made up 15 Feb) | 2 (15 Feb again, added no-objection) | 2.5 ($480K right, date wrong, missed risk) | 5 | 2.5-6.9 + thinking | slow | ? |
| LFM 2.5 1.2B | Locally AI (MLX) | no meter (~3s first word + 3-4s full) | 3 | 3 | 3 (all numbers + date right, invented weather risk, missed 85% vs 50%) | 5 (computed 50%) | ~3 | no | ? |

Quality guide: 5 = correct and clean, 3 = usable with edits, 1 = wrong or made-up facts.
Made-up numbers in T2 = automatic 1 (that kills trust).

Winner needs: 15+ tok/s AND average quality 3.5+.
Winner: LFM2.5 1.2B (38 tok/s, best speed, T3 4/5)  Backup: Qwen3 1.7B
Engine: decide in Phase 2 inside OUR app with identical settings (same quantization, low temperature).
Same model scored 2.75 in PocketPal vs 3.5 in Locally AI: app settings (quant, temperature) matter.

## Notes (Oct 30)
- Neither model finds the "85% paid vs 50% built" risk, and both invent dates or numbers.
  DECISION: code extracts numbers and computes the risk; the model only writes text
  from verified facts (same principle as LuBot: Python does the math, LLM writes).
- LFM2.5 1.2B: 3x faster, good writer (T3 4/5). Current leader.
- SmolLM3 3B: best writer (T3 5/5) but 13.7 tok/s plus thinking delay: too slow for the field demo.
- Qwen3 1.7B: half the speed of LFM2.5, also invents dates, puts facts under DECISIONS. Backup only.
- Gemma 3 1B: skipped, enough evidence.
- LFM 2.5 1.2B in Locally AI (MLX): avg 3.5 (meets target), all T2 numbers right, T3 5/5, a bit slower start than PocketPal.

## STEP 0.0 DONE (Oct 30 2026)
1. Model: LFM2.5 1.2B. Backup: Qwen3 1.7B.
2. Code extracts numbers and computes risks; the model only writes from verified facts.
3. Engine (llama.cpp vs MLX): decided in Phase 2 spike with identical settings, low temperature.

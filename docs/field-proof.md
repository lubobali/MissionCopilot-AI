# Field proof: Phase 6 on the iPhone (#150)

Every field flow, run by Lubo on his iPhone 13 Pro Max in airplane mode on Nov 8 2026, with the Kandor
mission (fictional data) downloaded from the staging server before. The screenshots stay private; this page
says what each one showed. One phone, one iOS version, a Staging build.

## The run

| Step | Flow | What the iPhone showed | Time |
|---|---|---|---|
| 1 | Before you go | Pack v9 checked, the model's self-test 8 of 8 right, speech files and space ready | the model answered in 3.6 s |
| 2 | Site walk | The walk finished and locked; the photo kept as signed evidence, full size, its place within 7 m | |
| 3 | Red flags | R067 "Milestone M3 is 37 days late and not met", MC-01 "Payments are 35 points ahead of the work built", each with "Computed from" in record names | |
| 4 | Scan invoice 14 and the progress report | 32 lines and a table read on the phone; with both pages, 8 of 8 facts found on their pages; with the invoice alone, the model invented the report's 3 facts, code locked them and the card said to scan the report | |
| 5 | Voice debrief | Recorded 0:22, kept as signed evidence; "Kandor Road visit" heard right this time; 2 notes written by code from the sentences said, word for word, who and by when found by code; a sentence tagged as a note with one tap; the saved notes open from the list | text in under 2 s |
| 6 | Ask opens | A spinner at once ("Opening this mission's data"), the chat with 128 sources in the same minute | under a minute, was 3 s of nothing |
| 7 | Ask, 6 questions | "How much has been paid?" USD 8,500,000; "What's done?" with the bank's disagreement on each walk item; "What's not done?" 3 actions and 2 milestones; the bridge "The bank's records and your site walk disagree" with both sides; "Combien a été payé ?" in French, typed without accents; an off-topic question refused | each answer in about a second |
| 8 | History | Every question kept with its time and whether it was answered | |
| - | Names and accents (AI Lab) | The same take of Lubo's voice through both engines: dictation with the mission's names 19.4% word errors and "$480,000" against 29.0% and "180,000 hours" ([speech spike](spikes/06-speech.md)) | 1.8 s against 0.7 s |

## Traceability: each fact back to its evidence

| Fact shown | Evidence | Rule |
|---|---|---|
| Invoice 14: amount due USD 480,000 | Scanned page 1, the words "480,000" at their place in the page's reading | `scan-invoice` v1 |
| Road built: 32 km | Scanned page 2, "32 of 64 km" | `scan-invoice` v1 (or `officer` with the page's place when corrected from the page, #151) |
| Road built: 1 km (an earlier test) | No page: typed by the officer, so Ask and the red flags say "you typed it, not on the page" | `officer` v1 |
| "Action, the contractor sends a new work plan by 30 November." | The 0:22 recording (signed evidence) and the sentence's place in its transcript | `debrief` v1 |
| Heard: 30 November | The same recording, the number's place | `debrief` v1 |
| USD 8,500,000 paid to date | The pack's six payments, added by code | code (CodeAnswers), cites the pack record |
| Milestone M3 is 37 days late | The pack's milestone M3, due date and status | red flag R067 v1 |
| Payments 35 points ahead of the work | The pack's payments, contract value and physical progress | red flag MC-01 v1 |

## Found by the run, each fixed test first before Phase 6 closed
- A correction could keep the value the page check had rejected (#151).
- The model changed the words of debrief notes and invented one; notes are now written by code (#152).
- "Kandor" was heard as "Counter"; the dictation engine with the mission's names, unsure words underlined
  and name suggestions (#153).
- Raw words on screen ("notMet", record paths) and a "done" answer without the bank's disagreement (#154).
- Ask took three seconds to open with nothing on screen; it now opens with one key unwrap (#150).
- Saved notes were shown nowhere; they open from the debrief now (#152).

# Field proof: Phase 7 on the iPhone (#164)

The report and its approval, run by Lubo on his iPhone 13 Pro Max on Nov 9 2026 with the same Kandor mission
(fictional data), in airplane mode, Staging builds installed from the Mac. The screenshots stay private; this
page says what each one showed. This mission holds every test of Phase 6 (three scans, many debriefs), so its
report is longer than a real one: the same records on a clean mission give 14 sentences
(`ios/MissionCopilotTests/ReportModelTests.swift`, the screenshot test).

## The run

| Step | What the iPhone showed | Time |
|---|---|---|
| 1 | The report opened, every sentence with a number; tapping 1 showed the contract's bank record (USD 10,000,000, supplier, status) | 11:55 AM |
| 2 | A sentence added with no fact picked: "No proof: Pick the facts this sentence comes from." and Save locked; removed, "77 sentences, each with its proof"; the draft saved | 11:55 AM |
| 3 | After 7.2.7: 51 sentences; one sentence per scanned invoice with its 8 facts behind one number, a typed value marked "(typed by you, not on the page)"; "Physical progress: 32 of 64 km of asphalt built, as of 30 Sep 2026."; only the overall rating | 12:46 PM |
| 4 | After 7.2.8: the walk's answers in words: "Broken road edges", "6 Nov 2026", "41.85988, -87.71320 (within 7 m)", "Photo taken"; the proof cards the same | 1:23 PM |
| 5 | Approve with Face ID grey, "Save the draft, then approve it."; saved (51 sentences), Approve on, "Face ID or your passcode signs it on this iPhone." | 5:18 PM |
| 6 | Face ID once; "Approved on this iPhone Nov 9, 2026 at 5:18 PM. It cannot change."; no Edit, Remove, Add or Save anywhere | 5:18 PM |
| 7 | Reopened: a spinner, "Writing the report from this mission's records…", then "Approved · 51 sentences, each with its proof" | 5:31 PM |

The cancel ("Not approved: you cancelled.") is covered by tests and was not tried on the phone before the
report was approved; it is proven in the Phase 9 run (#169).

## Traceability: each sentence back to its evidence

| Sentence | Facts | Evidence |
|---|---|---|
| USD 8,500,000 paid to date (the sum of 6 payments). | The pack record, rule `pack-record` v1 | The pack, signed evidence of kind `pack` (its manifest, the manifest's SHA-256 and the server's signature) |
| Your site walk: Has work on the Section 3 bridge started? Yes. | The answer, rule `walk-answer` v1 | The finished walk, signed evidence of kind `walk` |
| Red flag MC-01: Payments are 35 points ahead of the work built. | The flag, rule `red-flag` v1, strictly confidential | The pack (payments, contract value, physical progress) and the stored flags |
| From your scanned invoice: Invoice number: 14; … Section 3 bridge: Not started. | The invoice's 8 facts, rule `scan-invoice` v1 (or `officer`) | The scanned pages, each fact at its place on its page |
| From your debrief: The bridge works have not started. | The note, rule `debrief` v1 | The recording and the sentence's place in its transcript |
| The approval | The draft's sentences and their fact ids, who and when | One ECDSA P-256 signature by the phone's Secure Enclave approval key after Face ID, over those exact bytes (#163) |

## Found by the run, each fixed test first before Phase 7 closed
- 77 sentences: one per scanned fact, the same note from several debriefs, every rating (7.2.7).
- Walk answers raw: choice codes, ISO dates, the location's numbers, "Evidence:1" (7.2.8).
- The report page froze over a second with no spinner; it is built off the main thread now, like Ask (7.3.6).

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

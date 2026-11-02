# Architecture review, end of Iteration 1

A self-review against the responsibilities of a solutions architect role for corporate and field
digital services. Honest about gaps.

| Responsibility | Covered by | Status | Gap or next step |
|---|---|---|---|
| End-to-end architecture, options and trade-offs | architecture.md, ADRs 0001-0012 | Done | Revisit ADRs after the Iteration 2 spikes |
| Build vs buy decisions | ADR 0004 (open model vs built-in), 0007 (adapters), 0009 (own lineage vs C2PA) | Done | Licence check for a large organization (ADR 0004) |
| Non-functional requirements (offline, performance, privacy) | ADR 0003, 0006, 0008; bake-off numbers | Partly | Real performance only after Iteration 2 |
| Mobile: native vs hybrid, device capabilities, offline | ADR 0001, 0004 | Partly | Native chosen; device features proven in Iteration 2 |
| Notifications | API (submit, review) | Planned | Push notifications in Iteration 8 |
| Identity and access | OpenAPI bearer placeholder, ADR 0008 row-level security | Planned | Auth design in Iteration 3 |
| Personalization | Mission pack per officer, last-mission memory | Partly | No user preferences yet |
| Accessibility | Not yet | **Gap** | Add VoiceOver labels and Dynamic Type to the Definition of Done for UI stories |
| Responsible AI: governance, human oversight, monitoring | ADR 0003, 0005, 0009, 0010; approval gate; audit trail | Done (design) | Monitoring of model quality after release: roadmap |
| Integration with existing systems | ADR 0007, KoBo/XLSForm checklist, OC4IDS export | Partly | Real document hand-off is a mock |
| Security | Trust boundaries, ADR 0008, CI security checks | Partly | Threat model in Iteration 3 |
| Reuse, standards, engineering practice | ADR guard, contract tests, dataset tests, DoD, CI | Done | Keep guards growing with the code |

## Decisions from this review
1. **Accessibility** becomes part of the Definition of Done for any story with UI.
2. The Iteration 2 spikes must update ADR 0004 (engine) and confirm ADR 0008 (encryption stack) on the real phone.

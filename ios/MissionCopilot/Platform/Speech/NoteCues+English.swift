extension NoteCues {
    /// English: "agreed", "will", "need to", "late"; no mission words (a test checks).
    static let english = Words(
        spoken: [(.decision, "decision"), (.action, "action"), (.risk, "risk")],
        cues: [(.decision, "agreed"), (.decision, "decided"), (.decision, "approved"), (.decision, "accepted"),
               (.action, "will"), (.action, "shall"), (.action, "must"), (.action, "needs? to"), (.action, "has to"),
               (.action, "have to"), (.action, "promised?"), (.action, "commit"), (.action, "follow up"),
               (.action, "asked (the |us |him |her |them )?\\w+ to"),
               (.risk, "risks?"), (.risk, "late"), (.risk, "delay"), (.risk, "stuck"), (.risk, "problem"),
               (.risk, "shortage"), (.risk, "not on site")])
}

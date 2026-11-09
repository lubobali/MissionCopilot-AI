extension NoteCues {
    /// French: "convenu", "doit", "il faut", "retard"; no mission words (a test checks).
    static let french = Words(
        spoken: [(.decision, "décision"), (.action, "à faire"), (.risk, "risque")],
        cues: [(.decision, "décid"), (.decision, "convenu"), (.decision, "approuv"), (.decision, "accept"),
               (.action, "vais"), (.action, "va "), (.action, "allons"), (.action, "doit"), (.action, "doivent"),
               (.action, "devra"), (.action, "il faut"), (.action, "s'engage"), (.action, "promis"),
               (.action, "demande .{0,30}d['e]"),
               (.risk, "retard"), (.risk, "risque"), (.risk, "bloqu"), (.risk, "pénurie"), (.risk, "problème")])
}

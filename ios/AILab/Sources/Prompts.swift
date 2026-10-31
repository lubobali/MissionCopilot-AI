/// The same four tests as the bake-off (docs/bakeoff.md), so results are comparable.
enum BenchPrompts {
    static let all: [(id: String, text: String)] = [
        ("T1", t1), ("T1-FR", t1fr), ("T2", t2), ("T3", t3)
    ]

    static let t1 = """
    Turn this voice debrief into mission notes with 3 sections: DECISIONS, ACTION ITEMS (who, what, by when), \
    RISKS. Be short. Use only facts from the text.

    Debrief: ok so just met the deputy minister of transport, Mr. Okafor, and the road agency director. they \
    agreed to extend the contractor deadline to march 15 but only if the contractor shows a new work plan in two \
    weeks. the contractor is about 3 months late, they say the rains and fuel shortages. section 3 bridge still not \
    started. the minister asked the bank to send an engineer in january. also the payments look high compared to \
    what we saw on the road, need to check invoice 14. procurement for the second package is stuck, waiting for the \
    no-objection from our side. I promised to send the no-objection by friday.
    """

    static let t1fr = """
    Transforme ce compte rendu en notes de mission avec 3 sections en anglais : DECISIONS, ACTION ITEMS (qui, \
    quoi, quand), RISKS. Sois court.

    Compte rendu : réunion avec le vice-ministre des transports, M. Okafor, et le directeur de l'agence routière. \
    Ils acceptent de prolonger le délai de l'entreprise jusqu'au 15 mars, à condition qu'elle présente un nouveau \
    plan de travail dans deux semaines. L'entreprise a environ trois mois de retard à cause des pluies et des \
    pénuries de carburant. Le pont de la section 3 n'est pas commencé. Le ministre demande à la Banque d'envoyer un \
    ingénieur en janvier. Les paiements semblent élevés par rapport aux travaux réalisés, il faut vérifier la facture 14.
    """

    static let t2 = """
    Extract the facts from these two documents as a list: invoice number, amount, total paid so far, total budget, \
    percent of budget paid, percent of road built, dates. Then say in one line if there is a risk and why. Use only \
    numbers from the text.

    INVOICE No. 14 - Kandor Rural Roads Project, Package 1. Date: 12 Oct 2026. Contractor: Sahel Build Ltd. Amount \
    due: USD 480,000. Cumulative paid including this invoice: USD 8,500,000. Contract value: USD 10,000,000.

    CONTRACTOR PROGRESS REPORT, September 2026. Road section 1 to 3, total length 64 km. Completed: 32 km asphalt. \
    Section 3 bridge: not started. Planned completion: 15 Dec 2026.
    """

    static let t3 = """
    Write one short paragraph for a development-finance mission report (Aide-Memoire style), section \
    "Implementation Progress", formal and neutral tone, using only these facts:
    - Contractor about 3 months behind schedule (rains, fuel shortages)
    - 32 of 64 km built (50%), bridge at section 3 not started
    - 85% of the contract value paid (USD 8.5M of 10M)
    - Government agreed to extend the deadline to 15 March 2027 if a new work plan is submitted within two weeks
    - The mission recommends a technical audit of invoice 14
    """
}

/// Identical sampling settings for both engines (fair test).
enum BenchSettings {
    static let temperature: Float = 0.1
    static let topK: Int32 = 50
    static let repetitionPenalty: Float = 1.05
    static let maxTokens = 400
    static let repeats = 3
}

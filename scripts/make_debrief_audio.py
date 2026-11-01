"""Build the voice debrief test audio for spike #14 from the fictional demo dataset.

Writes docs/demo/audio/: debrief-en.m4a and debrief-fr.m4a (macOS voices Samantha and Thomas)
and answer-key.json (the exact script text and the key facts with how each is spoken). The script
and facts are pure and tested in CI; audio needs macOS `say` and `afconvert`, so it runs on a Mac
and the files are committed.

Run: uv run --directory backend python ../scripts/make_debrief_audio.py
"""

import json
import re
import subprocess  # noqa: S404 - fixed macOS tools, no user input
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / "docs" / "demo" / "kandor-rural-roads.json"
OUT = ROOT / "docs" / "demo" / "audio"
VOICES = {"en": "Samantha", "fr": "Thomas"}
MONTHS = {
    "en": [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ],
    "fr": [
        "janvier",
        "février",
        "mars",
        "avril",
        "mai",
        "juin",
        "juillet",
        "août",
        "septembre",
        "octobre",
        "novembre",
        "décembre",
    ],
}


@dataclass(frozen=True)
class Fact:
    name: str
    value: str  # the same in every language
    spoken: str  # exactly as it appears in this language's script


@dataclass(frozen=True)
class Debrief:
    language: str
    text: str
    facts: list[Fact]


def _date(iso: str, language: str) -> str:
    year, month, day = (int(part) for part in iso.split("-"))
    return f"{day} {MONTHS[language][month - 1]} {year}"


def _numbers(data: dict) -> dict:
    pack = data["pack"]
    invoice = next(d for d in data["documents"] if d["kind"] == "invoice")["fields"]
    report = next(d for d in data["documents"] if d["kind"] == "progress_report")["fields"]
    width = data["fieldFindings"]["roadWidth"]
    km_at = re.search(r"km (\d+)", width["where"])
    paid_percent = round(100 * invoice["cumulativePaid"] / invoice["contractValue"])
    built_percent = round(100 * report["kmCompleted"] / report["kmTotal"])
    return {
        "km": int(km_at.group(1)) if km_at else 0,
        "measured": f"{width['measuredM']:g}",
        "spec": f"{width['specM']:g}",
        "built": report["kmCompleted"],
        "total": report["kmTotal"],
        "invoice": invoice["invoiceNumber"],
        "amount": invoice["amount"],
        "paid_millions": f"{invoice['cumulativePaid'] / 1_000_000:g}",
        "paid_percent": paid_percent,
        "built_percent": built_percent,
        "gap": paid_percent - built_percent,
        "completion": report["plannedCompletion"],
        "reason": report["reasonGiven"],
        "contractor": pack["contractor"],
    }


def debrief(data: dict, language: str) -> Debrief:
    n = _numbers(data)
    fr = language == "fr"
    spoken = {
        "locationKm": f"kilomètre {n['km']}" if fr else f"kilometre {n['km']}",
        "roadWidthMeasured": f"{n['measured'].replace('.', ',')} mètres"
        if fr
        else f"{n['measured']} metres",
        "roadWidthSpec": f"{n['spec']} mètres" if fr else f"{n['spec']} metres",
        "kmBuilt": f"{n['built']} sur {n['total']}" if fr else f"{n['built']} of {n['total']}",
        "kmTotal": f"{n['total']} kilomètres" if fr else f"{n['total']} kilometres",
        "bridgeStatus": "pas commencé" if fr else "not started",
        "invoiceNumber": f"facture {n['invoice']}" if fr else f"invoice {n['invoice']}",
        "invoiceAmount": f"{n['amount']:,}".replace(",", " ") if fr else f"{n['amount']:,}",
        "paidTotal": f"{n['paid_millions'].replace('.', ',')} millions"
        if fr
        else f"{n['paid_millions']} million",
        "paidPercent": f"{n['paid_percent']} pour cent" if fr else f"{n['paid_percent']} percent",
        "plannedCompletion": _date(n["completion"], language),
    }
    values = {
        "locationKm": f"km {n['km']}",
        "roadWidthMeasured": f"{n['measured']} m",
        "roadWidthSpec": f"{n['spec']} m",
        "kmBuilt": str(n["built"]),
        "kmTotal": f"{n['total']} km",
        "bridgeStatus": "not_started",
        "invoiceNumber": str(n["invoice"]),
        "invoiceAmount": str(n["amount"]),
        "paidTotal": f"{n['paid_millions']} million",
        "paidPercent": f"{n['paid_percent']} percent",
        "plannedCompletion": n["completion"],
    }
    s = spoken
    if fr:
        text = (
            "Ceci est un débriefing de formation fictif "
            "pour le projet de routes rurales de Kandor, lot 1. "
            "J'ai visité le chantier du 10 au 14 novembre 2026. "
            f"Au {s['locationKm']}, j'ai mesuré la largeur de la route "
            f"à {s['roadWidthMeasured']}. "
            f"La spécification est de {s['roadWidthSpec']}, "
            "donc la route est trop étroite à cet endroit. "
            "J'ai une photo et une mesure au ruban. "
            f"L'entreprise {n['contractor']} déclare "
            f"{s['kmBuilt']} kilomètres d'asphalte construits, "
            f"sur un total de {s['kmTotal']}, soit la moitié de la route. "
            f"Le pont de la section 3 n'est {s['bridgeStatus']}. "
            "L'entreprise donne comme raison les pluies et les pénuries de carburant. "
            f"La {s['invoiceNumber']} demande {s['invoiceAmount']} dollars. "
            f"Avec cette facture, les paiements atteignent {s['paidTotal']} de dollars, "
            f"soit {s['paidPercent']} de la valeur du contrat. "
            f"L'avancement physique n'est que de {n['built_percent']} pour cent, "
            f"donc les paiements ont {n['gap']} points d'avance sur les travaux. "
            "Il faut un suivi avant le prochain paiement. "
            f"La date d'achèvement prévue est le {s['plannedCompletion']}. "
            "Je ne pense pas que cette date soit réaliste sans le pont. "
            "La lettre du ministère prolonge le délai jusqu'au 15 mars 2027, "
            "si un nouveau plan de travail arrive sous deux semaines. "
            "Prochaines étapes : demander le plan de travail révisé, "
            "mesurer la largeur en deux autres points, "
            "et suspendre le prochain paiement jusqu'au début des travaux du pont. "
            "Fin du débriefing."
        )
    else:
        text = (
            "This is a fictional training debrief for the Kandor Rural Roads Project, Package 1. "
            "I visited the site from the 10th to the 14th of November 2026. "
            f"At {s['locationKm']}, I measured the road width at {s['roadWidthMeasured']}. "
            f"The specification is {s['roadWidthSpec']}, so the road is too narrow at that point. "
            "I have a photo and a tape measurement. "
            f"{n['contractor']} reports {s['kmBuilt']} kilometres of asphalt built, "
            f"out of {s['kmTotal']} in total, which is half of the road. "
            f"The Section 3 bridge is {s['bridgeStatus']}. "
            f"The contractor gave {n['reason']} as the reason. "
            f"{s['invoiceNumber'].capitalize()} asks for {s['invoiceAmount']} dollars. "
            f"With this invoice, payments reach {s['paidTotal']} dollars, "
            f"which is {s['paidPercent']} of the contract value. "
            f"Physical progress is only {n['built_percent']} percent, "
            f"so payments are {n['gap']} points ahead of the work. "
            "This needs a follow up before the next payment. "
            f"The planned completion date is {s['plannedCompletion']}. "
            "I do not think that date is realistic without the bridge. "
            "The ministry letter extends the deadline to 15 March 2027, "
            "if a new work plan arrives within two weeks. "
            "Next steps: ask the contractor for the revised work plan, "
            "check the road width at two more points, "
            "and hold the next payment until work on the bridge has started. End of debrief."
        )
    facts = [Fact(name=key, value=values[key], spoken=spoken[key]) for key in spoken]
    return Debrief(language=language, text=text, facts=facts)


def answer_key(data: dict) -> dict:
    """What the phone must hear: the exact text and the key facts, per language."""
    return {
        language: {
            "voice": VOICES[language],
            "text": script.text,
            "facts": [asdict(fact) for fact in script.facts],
        }
        for language in VOICES
        for script in [debrief(data, language)]
    }


def render(script: Debrief, path: Path) -> None:  # pragma: no cover - macOS tools, checked by ear
    with tempfile.TemporaryDirectory() as tmp:
        aiff = Path(tmp) / "debrief.aiff"
        say = ["/usr/bin/say", "-v", VOICES[script.language], "-o", str(aiff), script.text]
        subprocess.run(say, check=True)  # noqa: S603 - fixed macOS tool, text from our own dataset
        aac = ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(aiff), str(path)]
        subprocess.run(aac, check=True)  # noqa: S603 - fixed macOS tool


def main() -> None:  # pragma: no cover
    data = json.loads(DATASET.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    for language in VOICES:
        render(debrief(data, language), OUT / f"debrief-{language}.m4a")
    key = json.dumps(answer_key(data), indent=2, ensure_ascii=False) + "\n"
    (OUT / "answer-key.json").write_text(key, encoding="utf-8")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()

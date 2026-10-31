"""Build the scan test documents for spike #15 from the fictional demo dataset.

Writes docs/demo/scans/: invoice-14.png, progress-report-2026-09.png (A4 at 200 dpi, printable)
and answer-key.json (the facts and table rows the phone must read back). The content functions are
pure and tested in CI; drawing needs Pillow and the macOS Arial font, so it runs on a Mac and the
images are committed.

Run: uv run --directory backend python ../scripts/make_scan_documents.py
"""

import json
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / "docs" / "demo" / "kandor-rural-roads.json"
OUT = ROOT / "docs" / "demo" / "scans"
FOOTER = [
    "Fictional demo document. Kandor is not a real country; all names and amounts are invented."
]


@dataclass(frozen=True)
class Table:
    caption: str
    headers: list[str]
    rows: list[list[str]]


@dataclass(frozen=True)
class Page:
    name: str
    title: str
    lines: list[str]
    table: Table
    footer: list[str] = field(default_factory=lambda: list(FOOTER))


def spoken_date(iso: str, short: bool = False) -> str:
    """'2026-10-12' -> '12 October 2026' (or '12 Oct 2026'): how dates appear on real paperwork."""
    day = date.fromisoformat(iso)
    return day.strftime("%-d %b %Y" if short else "%-d %B %Y")


def money(amount: int) -> str:
    return f"{amount:,}"


def _document(data: dict, kind: str) -> dict:
    return next(doc for doc in data["documents"] if doc["kind"] == kind)


def invoice_page(data: dict) -> Page:
    fields = _document(data, "invoice")["fields"]
    mission = data["mission"]
    return Page(
        name="invoice-14",
        title=f"Invoice No. {fields['invoiceNumber']}",
        lines=[
            fields["contractor"],
            "Plot 7, Ring Road, Kandor City",
            f"{mission['project']} ({mission['projectRef']})",
            f"Invoice No. {fields['invoiceNumber']}",
            f"Date: {spoken_date(fields['date'])}",
            "Bill to: Ministry of Public Works, Kandor",
            f"Amount due this invoice: USD {money(fields['amount'])}",
            f"Contract value: USD {money(fields['contractValue'])}",
            f"Paid to date, including this invoice: USD {money(fields['cumulativePaid'])}",
        ],
        table=Table(
            caption="Payment history",
            headers=["Date", "Reference", "Amount (USD)"],
            rows=[
                [spoken_date(p["date"], short=True), p["reference"], money(p["amount"])]
                for p in data["pack"]["payments"]
            ],
        ),
    )


def progress_report_page(data: dict) -> Page:
    fields = _document(data, "progress_report")["fields"]
    progress = data["pack"]["physicalProgress"]
    mission = data["mission"]
    return Page(
        name="progress-report-2026-09",
        title="Contractor progress report, September 2026",
        lines=[
            data["pack"]["contractor"],
            f"{mission['project']} ({mission['projectRef']})",
            f"Status as of {spoken_date(progress['asOf'])}",
            f"Road built: {fields['kmCompleted']} of {fields['kmTotal']} km of asphalt",
            f"Section 3 bridge: {fields['bridgeSection3']}",
            f"Reason given: {fields['reasonGiven']}",
            f"Planned completion: {spoken_date(fields['plannedCompletion'])}",
        ],
        table=Table(
            caption="Milestones",
            headers=["Milestone", "Due", "Met"],
            rows=[
                [
                    m["title"],
                    spoken_date(m["dueDate"], short=True),
                    spoken_date(m["dateMet"], short=True) if m["dateMet"] else "",
                ]
                for m in data["pack"]["milestones"]
            ],
        ),
    )


def answer_key(data: dict) -> dict:
    """What the phone must read back: the 8 facts of spike #13 and every table row."""
    invoice = _document(data, "invoice")["fields"]
    report = _document(data, "progress_report")["fields"]
    pages = [invoice_page(data), progress_report_page(data)]
    return {
        "facts": {
            "invoiceNumber": invoice["invoiceNumber"],
            "invoiceDate": invoice["date"],
            "amountDue": invoice["amount"],
            "cumulativePaid": invoice["cumulativePaid"],
            "contractValue": invoice["contractValue"],
            "kmCompleted": report["kmCompleted"],
            "kmTotal": report["kmTotal"],
            "bridgeStatus": report["bridgeSection3"].replace(" ", "_"),
        },
        "tables": {p.name: {"headers": p.table.headers, "rows": p.table.rows} for p in pages},
    }


def render(
    page: Page, path: Path
) -> None:  # pragma: no cover - drawing, checked by eye and by the phone
    from PIL import Image, ImageDraw, ImageFont

    fonts = Path("/System/Library/Fonts/Supplemental")
    regular = ImageFont.truetype(str(fonts / "Arial.ttf"), 34)
    bold = ImageFont.truetype(str(fonts / "Arial Bold.ttf"), 34)
    title = ImageFont.truetype(str(fonts / "Arial Bold.ttf"), 54)
    small = ImageFont.truetype(str(fonts / "Arial.ttf"), 24)
    width, height, margin = 1654, 2339, 130  # A4 at 200 dpi
    image = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(image)

    y = margin
    draw.text((margin, y), page.title, font=title, fill=0)
    y += 110
    for line in page.lines:
        draw.text((margin, y), line, font=regular, fill=0)
        y += 56
    y += 40
    draw.text((margin, y), page.table.caption, font=bold, fill=0)
    y += 64

    columns = [margin, margin + 520, margin + 1000, width - margin]
    if page.name.startswith("invoice"):
        columns = [margin, margin + 330, margin + 900, width - margin]
    row_height = 66
    for index, row in enumerate([page.table.headers, *page.table.rows]):
        draw.line([(columns[0], y), (columns[-1], y)], fill=0, width=2)
        for col, cell in enumerate(row):
            draw.text(
                (columns[col] + 16, y + 16), cell, font=bold if index == 0 else regular, fill=0
            )
        y += row_height
    draw.line([(columns[0], y), (columns[-1], y)], fill=0, width=2)
    top = y - row_height * (len(page.table.rows) + 1)
    for x in columns:
        draw.line([(x, top), (x, y)], fill=0, width=2)

    for line in page.footer:
        draw.text((margin, height - margin), line, font=small, fill=90)
    image.save(path, optimize=True)


def main() -> None:  # pragma: no cover
    data = json.loads(DATASET.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    for page in (invoice_page(data), progress_report_page(data)):
        render(page, OUT / f"{page.name}.png")
    key = json.dumps(answer_key(data), indent=2, ensure_ascii=False) + "\n"
    (OUT / "answer-key.json").write_text(key, encoding="utf-8")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()

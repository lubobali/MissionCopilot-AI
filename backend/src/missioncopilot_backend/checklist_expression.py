"""The checklist expression reader, the phone's (ChecklistExpression.swift) in Python (#93, T54).

The server needs the same answer as the phone to every question that matters before it
publishes a checklist: can the expression be read at all, and does it carry a regex() pattern
that could hang the phone (over 200 characters, backreferences or lookbehind)? A rule the phone
cannot read is kept by the phone, so it must be kept here too, even if it holds a risky pattern.
Never run as code: the expression is only split into tokens and parsed, with the phone's caps on
length and nesting.
"""

import re

MAX_LENGTH = 500
MAX_DEPTH = 32
MAX_PATTERN = 200
FUNCTIONS = {
    "not": (1, 1), "selected": (2, 2), "count-selected": (1, 1), "string-length": (0, 1),
    "regex": (2, 2), "if": (3, 3), "coalesce": (2, 2), "number": (1, 1), "int": (1, 1),
    "today": (0, 0),
}  # fmt: skip
LEVELS = [{"or"}, {"and"}, {"=", "!="}, {"<", "<=", ">", ">="}, {"+", "-"}, {"*", "div", "mod"}]
TOKENS = [
    ("ref", re.compile(r"\$\{([a-z][a-z0-9_]*)\}")),
    ("num", re.compile(r"[0-9]+(\.[0-9]*)?|\.[0-9]+")),
    ("str", re.compile(r"'([^']*)'|\"([^\"]*)\"")),
    ("dot", re.compile(r"\.")),
    ("word", re.compile(r"[A-Za-z_][A-Za-z0-9_:\-]*")),
    ("sym", re.compile(r"!=|<=|>=|[=<>+\-*(),]")),
]
RISKY = re.compile(r"\\[1-9]|\\k|\(\?<[=!]")


class UnsafePattern(Exception):
    """A regex() pattern that could make the phone hang."""


class _CannotRead(Exception):
    pass


def _split(text: str) -> list[tuple[str, str]] | None:
    tokens, at = [], 0
    while at < len(text):
        if text[at].isspace():
            at += 1
            continue
        for kind, pattern in TOKENS:
            if match := pattern.match(text, at):
                if kind == "str":
                    value = match.group(1) if match.group(1) is not None else match.group(2)
                else:
                    value = match.group(1) if kind == "ref" else match.group(0)
                tokens.append((kind, value))
                at = match.end()
                break
        else:
            return None
    return tokens or None


class _Parser:
    def __init__(self, tokens: list[tuple[str, str]]):
        self.tokens, self.at, self.depth, self.patterns = tokens, 0, 0, []

    def _peek(self) -> tuple[str, str] | None:
        return self.tokens[self.at] if self.at < len(self.tokens) else None

    def _take(self, text: str) -> bool:
        token = self._peek()
        if token and token[0] in ("word", "sym") and token[1] == text:
            self.at += 1
            return True
        return False

    def _enter(self) -> None:
        self.depth += 1
        if self.depth > MAX_DEPTH:
            raise _CannotRead

    def all(self) -> None:
        self._binary(0)
        if self.at != len(self.tokens):
            raise _CannotRead

    def _binary(self, level: int) -> tuple:
        if level == len(LEVELS):
            return self._unary()
        left = self._binary(level + 1)
        while (token := self._peek()) and token[0] in ("word", "sym") and token[1] in LEVELS[level]:
            self.at += 1
            left = ("op", left, self._binary(level + 1))
        return left

    def _unary(self) -> tuple:
        if not self._take("-"):
            return self._primary()
        self._enter()
        inner = self._unary()
        self.depth -= 1
        return ("neg", inner)

    def _primary(self) -> tuple:
        token = self._peek()
        if token is None:
            raise _CannotRead
        self.at += 1
        kind, value = token
        if kind in ("num", "str", "ref", "dot"):
            return (kind, value)
        if token == ("sym", "("):
            self._enter()
            inner = self._binary(0)
            if not self._take(")"):
                raise _CannotRead
            self.depth -= 1
            return inner
        if kind == "word" and value in FUNCTIONS and self._take("("):
            return self._call(value)
        raise _CannotRead

    def _call(self, name: str) -> tuple:
        self._enter()
        arguments = []
        if not self._take(")"):
            arguments.append(self._binary(0))
            while self._take(","):
                arguments.append(self._binary(0))
            if not self._take(")"):
                raise _CannotRead
        self.depth -= 1
        least, most = FUNCTIONS[name]
        if not least <= len(arguments) <= most:
            raise _CannotRead
        if name == "regex":
            self.patterns.append(arguments[-1])
        return ("call", name, arguments)


def read(text: str) -> bool:
    """True when the phone can read the expression; raises UnsafePattern for a risky pattern in one
    it can read."""
    tokens = _split(text) if len(text) <= MAX_LENGTH else None
    if tokens is None:
        return False
    parser = _Parser(tokens)
    try:
        parser.all()
    except _CannotRead:
        return False
    readable = True
    for pattern in parser.patterns:
        if pattern[0] != "str":
            readable = False
        elif len(pattern[1]) > MAX_PATTERN or RISKY.search(pattern[1]):
            raise UnsafePattern
    return readable

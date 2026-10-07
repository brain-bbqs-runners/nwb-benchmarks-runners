"""Put each sentence in a Markdown file on its own single line.

Two problems are detected and fixed in place:

- a sentence wrapped across multiple lines is joined back onto one line;
- a line holding several sentences is split so each sentence gets its own line
  (list items are left as they are).

Files that needed changes are rewritten and the script exits non-zero, so
pre-commit reports the hook as failed until the fixed files are staged.

Usage: python scripts/check_sentence_per_line.py FILE [FILE ...]
"""

import re
import sys

# Characters that may legitimately end a line of prose.
LINE_ENDINGS = (".", "!", "?", ":", ";")
# Trailing characters that may follow the sentence-ending punctuation.
TRAILING_CLOSERS = "\"')]*_`"

# Words that end with a period but do not end a sentence (compared lowercase).
ABBREVIATIONS = {
    # Latin
    "e.g.",
    "i.e.",
    "etc.",
    "al.",  # et al.
    "cf.",
    "viz.",
    "vs.",
    "v.",
    "ca.",
    "c.",
    "approx.",
    "resp.",
    "ibid.",
    "op.",  # op. cit.
    "n.b.",
    "seq.",  # et seq.
    # References within the manuscript
    "fig.",
    "figs.",
    "tab.",
    "tabs.",
    "eq.",
    "eqs.",
    "ref.",
    "refs.",
    "sec.",
    "secs.",
    "ch.",
    "app.",
    "suppl.",
    "vol.",
    "vols.",
    "no.",
    "nos.",
    "p.",
    "pp.",
    "ed.",
    "eds.",
    # Titles
    "dr.",
    "mr.",
    "mrs.",
    "ms.",
    "prof.",
    "st.",
    "jr.",
    "sr.",
    # Other common abbreviations
    "inc.",
    "ltd.",
    "co.",
    "corp.",
    "dept.",
    "univ.",
    "min.",
    "max.",
    "avg.",
    "est.",
    "misc.",
    "a.k.a.",
    "jan.",
    "feb.",
    "mar.",
    "apr.",
    "jun.",
    "jul.",
    "aug.",
    "sep.",
    "sept.",
    "oct.",
    "nov.",
    "dec.",
}
# Dotted abbreviations such as "U.S." or "a.k.a.".
DOTTED_ABBREVIATION_RE = re.compile(r"(?:[A-Za-z]\.){2,}")

FENCE_RE = re.compile(r"^\s*(```|~~~)")
BLOCK_START_RE = re.compile(
    r"""^\s*(
        \#{1,6}\s          # heading
        | [-*+]\s          # bullet list item
        | \d+[.)]\s        # ordered list item
        | >                # blockquote
        | \|               # table row
        | <                # HTML block / comment
        | !\[              # image
        | \[\^?[^\]]+\]:   # link reference / footnote definition
        | (-{3,}|\*{3,}|_{3,}|={3,})\s*$  # thematic break / setext underline
    )""",
    re.VERBOSE,
)
LIST_MARKER_RE = re.compile(r"([-*+]|\d+[.)])\s+")
# Candidate sentence boundary: terminal punctuation, optional closers,
# whitespace, then something that starts a new sentence.
BOUNDARY_RE = re.compile(r"[.!?][\"')\]*_`]*(\s+)(?=[A-Z`\[*\"])")
BOLD_LABEL_RE = re.compile(r"(\*\*|__)[^*_]+(\*\*|__)")
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def ends_sentence(line: str, /) -> bool:
    stripped = line.rstrip()
    # Explicit Markdown hard line breaks are intentional.
    if line.endswith("  ") or stripped.endswith("\\"):
        return True
    stripped = stripped.rstrip(TRAILING_CLOSERS)
    return stripped.endswith(LINE_ENDINGS)


def is_single_line_construct(line: str, /) -> bool:
    """Lines that are never joined with or split into other lines."""
    return line.lstrip().startswith(("|", "#", "<", ">", "![", "[")) or bool(
        re.match(r"^\s*(-{3,}|\*{3,}|_{3,}|={3,})\s*$", line)
    )


def classify(lines: list[str], /) -> list[bool]:
    """Return, for each line, whether it is prose that may be reflowed."""
    prose = [False] * len(lines)
    in_fence = False
    in_front_matter = bool(lines) and lines[0].strip() == "---"
    in_html_comment = False

    for index, line in enumerate(lines):
        if in_front_matter:
            if index > 0 and line.strip() in ("---", "..."):
                in_front_matter = False
            continue
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if in_html_comment:
            if "-->" in line:
                in_html_comment = False
            continue
        if "<!--" in line and "-->" not in line:
            in_html_comment = True
            continue
        if not line.strip() or is_single_line_construct(line):
            continue
        prose[index] = True

    return prose


def find_list_lines(lines: list[str], /) -> list[bool]:
    """Return, for each line, whether it belongs to a list item."""
    in_list = [False] * len(lines)
    inside = False
    previous_blank = False
    for index, line in enumerate(lines):
        if not line.strip():
            previous_blank = True
            continue
        if LIST_MARKER_RE.match(line.lstrip()):
            inside = True
        elif previous_blank and not line.startswith((" ", "\t")):
            inside = False
        elif line.lstrip().startswith("#"):
            inside = False
        in_list[index] = inside
        previous_blank = False
    return in_list


def split_sentences(text: str, /) -> list[str]:
    """Split one line of prose into sentences."""
    # Hide inline code so punctuation inside it is never treated as a boundary.
    masked = INLINE_CODE_RE.sub(lambda m: "`" + "x" * (len(m.group()) - 2) + "`", text)

    sentences = []
    start = 0
    for match in BOUNDARY_RE.finditer(masked):
        chunk = masked[start : match.start(1)]
        # Inside bold text, or a bold lead-in label such as "**Figure 3.**".
        if (
            chunk.count("**") % 2
            or chunk.count("__") % 2
            or BOLD_LABEL_RE.fullmatch(chunk)
        ):
            continue
        words = masked[start : match.start() + 1].split()
        # A leading number such as "1." enumerates rather than ends a sentence.
        if len(words) == 1 and re.fullmatch(r"\W*\d+\.", words[0]):
            continue
        last_word = words[-1].lstrip("(\"'[*_") if words else ""
        if last_word.lower() in ABBREVIATIONS or DOTTED_ABBREVIATION_RE.fullmatch(
            last_word
        ):
            continue
        # A single capital letter followed by a period is usually an initial.
        if re.fullmatch(r"[A-Z]\.", last_word):
            continue
        whitespace_start = match.start(1)
        sentences.append(text[start:whitespace_start])
        start = match.end(1)
    sentences.append(text[start:])
    return sentences


def reflow(lines: list[str], /) -> tuple[list[str], list[str]]:
    """Return the fixed lines and a description of each problem found."""
    prose = classify(lines)
    in_list = find_list_lines(lines)
    problems = []

    # Join wrapped sentences.
    joined: list[tuple[int, str, bool]] = []
    for index, line in enumerate(lines):
        continues_previous = (
            prose[index]
            and joined
            and joined[-1][2]
            and index > 0
            and prose[index - 1]
            and not BLOCK_START_RE.match(line)
            and not ends_sentence(joined[-1][1])
        )
        if continues_previous:
            first_line, previous, _ = joined[-1]
            problems.append(
                f"{first_line + 1}: sentence is wrapped onto line {index + 1}"
            )
            joined[-1] = (first_line, previous.rstrip() + " " + line.strip(), True)
        else:
            joined.append((index, line, prose[index]))

    # Split lines holding several sentences, except within list items.
    fixed = []
    for first_line, line, is_prose in joined:
        if not is_prose or in_list[first_line]:
            fixed.append(line)
            continue
        content = line.lstrip()
        indent = line[: len(line) - len(content)]
        body = content.rstrip()
        trailing = content[len(body) :]

        sentences = split_sentences(body)
        if len(sentences) > 1:
            problems.append(f"{first_line + 1}: line holds {len(sentences)} sentences")
        sentences[-1] += trailing
        fixed.extend(indent + sentence for sentence in sentences)

    return fixed, problems


def fix_file(path: str, /) -> list[str]:
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    newline = "\r\n" if "\r\n" in text else "\n"
    has_final_newline = text.endswith(("\n", "\r\n"))
    lines = text.splitlines()

    fixed, problems = reflow(lines)
    if fixed != lines:
        new_text = newline.join(fixed) + (newline if has_final_newline else "")
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new_text)
    return [f"{path}:{problem}" for problem in problems]


def main(argv: list[str], /) -> int:
    problems = []
    for path in argv:
        problems.extend(fix_file(path))
    for problem in problems:
        print(problem)
    if problems:
        print(
            "Fixed: each sentence is now on its own line. Review and stage the changes."
        )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Quality scorer for converted documents: compares a converted .md against the
PDF text layer the app actually saw and reports every known defect class.

Usage:
    python3 eval/score.py <source.pdf | source.txt> <converted.md> [more.md ...]

Metrics (id extraction and gating are 1:1 ports of ClauseAudit.swift so this
predicts exactly what the in-app audit will flag):
    missing ids     clause numbers in the source but not the answer (app warns)
    invented ids    multi-level clause numbers in the answer but not the source
    bare-number     paragraphs numbered "1.", "2." under a multi-level section
    inventions      where the source has no such printed clause number
    duplicates      the same subsection label twice within one section
    order flips     numeric decreases between consecutive same-prefix labels
    content recall  distinctive long words of the source found in the answer
"""
import os
import re
import subprocess
import sys
import tempfile
import unicodedata

ID_RE = re.compile(r"(?<![0-9.,])([1-9][0-9]?(?:\.[1-9][0-9]?){1,3})(?![0-9,])(?!\.[0-9])")
MIN_SOURCE_IDS = 5  # ClauseAudit.minSourceIds


def audit_ids(text):
    """Port of ClauseAudit.ids(in:) — multi-level clause ids, noise-guarded."""
    return set(ID_RE.findall(text))


def has_neighbor(cid, pool):
    """Port of ClauseAudit.hasClauseNeighbor — real clauses live in numbered runs."""
    comps = cid.split(".")
    prefix, last = comps[:-1], int(comps[-1])
    sib = lambda n: ".".join(prefix + [str(n)])
    if last > 1 and sib(last - 1) in pool:
        return True
    if sib(last + 1) in pool:
        return True
    return len(prefix) >= 2 and ".".join(prefix) in pool


def gated(diff, pool):
    return sorted((c for c in diff if has_neighbor(c, pool)),
                  key=lambda s: [int(x) for x in s.split(".")])


def contains_loosely(cid, source):
    """Port of ClauseAudit.containsLoosely: the text layer sometimes splits a
    printed number across a line break ("Ziffer 6.\\n25"); tolerate whitespace
    inside the id before calling an answer id invented."""
    return re.search(r"\s*\.\s*".join(cid.split(".")), source) is not None


def dehyphenate(text):
    """The PDF text layer breaks words at column edges ("Vor-\\nbereitung") and
    with soft hyphens; rejoin so word-level recall does not count them missing.
    A soft hyphen absorbs any following whitespace: it only ever sits inside a
    word, so whatever follows it is the same word's continuation. A hyphen
    between two lowercase letters is a line-break hyphen that survived the
    reflow ("Vorsorgever-sicherung"); real German compounds continue with an
    uppercase letter ("Spezial-Schadenersatz") or a space ("Buß- und") and are
    left alone."""
    text = re.sub("­\\s*", "", text)
    text = re.sub(r"([a-zäöüß])-\s*\n\s*([a-zäöüß])", r"\1\2", text)
    return re.sub(r"([a-zäöüß])-([a-zäöüß])", r"\1\2", text)


def long_words(text):
    words = re.findall(r"[A-Za-zÄÖÜäöüß]{12,}", dehyphenate(text))
    return {unicodedata.normalize("NFC", w).lower() for w in words}


def md_sections(md):
    """Parse the renderer's output shape: '## <id> <title>' + '**<label>.** ...'."""
    sections, current = [], None
    for line in md.split("\n"):
        h = re.match(r"^##\s+(\S.*)$", line)
        if h:
            m = re.match(r"^(\d{1,2}(?:\.\d{1,2})*)\.?(?:\s|$)", h.group(1))
            current = {"id": m.group(1) if m else None, "heading": h.group(1), "labels": []}
            sections.append(current)
            continue
        s = re.match(r"^\*\*([^*]+?)\.?\*\*\s+(.*)$", line)
        if s and current is not None:
            current["labels"].append((s.group(1).strip(), s.group(2)))
    return sections


def source_shows_number(n, content, source):
    """Port of ClauseAudit.sourceShowsNumber: printed inline enumerations keep
    their numbers adjacent to their text in the text layer, so "<n>." right
    before the paragraph's first words means the numbering is the document's
    own. Too little text to judge counts as printed (never flag weakly)."""
    key = re.sub(r"[^0-9a-zäöüß]", "", content.lower())[:24]
    if len(key) < 4:
        return True
    gap = "[\\s­.,;:()'\"„“/-]*"
    pattern = (r"(?<![0-9.,])" + re.escape(n) + r"[.)]?" + gap
               + gap.join(re.escape(c) for c in key))
    return re.search(pattern, source, re.IGNORECASE) is not None


def bare_number_inventions(sections, source_ids, source):
    """A paragraph labeled with a bare number under a multi-level numeric section
    ("1." under "6.8") claims a printed clause 6.8.1. Flag it when the source
    neither prints the number inline before the paragraph text nor contains the
    composite clause id, or when the same section already carries the explicit
    multi-level id (then the bare label is a duplicate claim)."""
    if len(source_ids) < MIN_SOURCE_IDS:
        return []
    flags = []
    for sec in sections:
        sid = sec["id"]
        if not sid or "." not in sid:
            continue
        explicit = {label for label, _ in sec["labels"]}
        for label, content in sec["labels"]:
            if not re.fullmatch(r"\d{1,2}", label):
                continue
            if source_shows_number(label, content, source):
                continue
            composite = f"{sid}.{label}"
            if composite not in source_ids or composite in explicit:
                flags.append(f"{label}. under {sid}")
    return flags


def duplicates_and_order(sections):
    dups, flips = [], []
    for sec in sections:
        # A rendered table of contents restarts numbering per Abschnitt inside
        # one section, so repeats and decreases there are layout, not defects.
        if "inhaltsverzeichnis" in sec["heading"].lower():
            continue
        numeric = [l for l, _ in sec["labels"] if re.fullmatch(r"\d{1,2}(\.\d{1,2})*", l)]
        seen = set()
        for l in numeric:
            if l in seen:
                dups.append(f"{l} in {sec['id'] or sec['heading'][:30]}")
            seen.add(l)
        for a, b in zip(numeric, numeric[1:]):
            ac, bc = [int(x) for x in a.split(".")], [int(x) for x in b.split(".")]
            if ac[:-1] == bc[:-1] and bc[-1] < ac[-1]:
                flips.append(f"{a} -> {b} in {sec['id'] or sec['heading'][:30]}")
    return dups, flips


def load_source(path):
    if not path.lower().endswith(".pdf"):
        return open(path, encoding="utf-8").read()
    here = os.path.dirname(os.path.abspath(__file__))
    dumper = os.path.join(tempfile.gettempdir(), "pdfconv_dump_text")
    src = os.path.join(here, "dump_text.swift")
    if not os.path.exists(dumper) or os.path.getmtime(dumper) < os.path.getmtime(src):
        subprocess.run(["swiftc", "-O", "-o", dumper, src], check=True)
    return subprocess.run([dumper, path], check=True, capture_output=True, text=True).stdout


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    source = load_source(sys.argv[1])
    source_ids = audit_ids(source)
    source_words = long_words(source)
    print(f"SOURCE {os.path.basename(sys.argv[1])}: {len(source)} chars | "
          f"{len(source_ids)} clause ids | {len(source_words)} distinct long words")
    if len(source_ids) < MIN_SOURCE_IDS:
        print("note: below minSourceIds, the in-app audit would not run on this document")

    audited = len(source_ids) >= MIN_SOURCE_IDS
    for path in sys.argv[2:]:
        md = open(path, encoding="utf-8").read()
        answer_ids = audit_ids(md)
        # Below minSourceIds the in-app audit is silent; report the same.
        missing = gated(source_ids - answer_ids, source_ids) if audited else []
        invented = [c for c in gated(answer_ids - source_ids, answer_ids)
                    if not contains_loosely(c, source)] if audited else []
        sections = md_sections(md)
        bare = bare_number_inventions(sections, source_ids, source)
        dups, flips = duplicates_and_order(sections)
        words = long_words(md)
        recall = len(source_words & words) / max(1, len(source_words))
        print(f"\n=== {os.path.basename(path)}: {len(md)} chars ===")
        print(f"id coverage      {len(source_ids & answer_ids)}/{len(source_ids)} "
              f"({100 * len(source_ids & answer_ids) / max(1, len(source_ids)):.1f}%)")
        print(f"missing ids      {len(missing)}: {missing[:20]}")
        print(f"invented ids     {len(invented)}: {invented[:20]}")
        print(f"bare inventions  {len(bare)}: {bare[:12]}")
        print(f"duplicate labels {len(dups)}: {dups[:8]}")
        print(f"order flips      {len(flips)}: {flips[:8]}")
        missing_words = sorted(source_words - words)
        print(f"content recall   {100 * recall:.1f}% "
              f"(missing {len(missing_words)}: {missing_words[:10]})")


if __name__ == "__main__":
    main()

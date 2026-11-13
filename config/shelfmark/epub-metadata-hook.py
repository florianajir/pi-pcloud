#!/usr/bin/env python3
"""Shelfmark post-import hook: repair the EPUB metadata Kavita groups and credits books by.

Shelfmark runs this (CUSTOM_SCRIPT) right after it copies a download into the library and
pipes the task in as JSON (CUSTOM_SCRIPT_JSON_PAYLOAD). Kavita's Book library builds series
from `calibre:series` + `calibre:series_index` (or the EPUB 3 collection pair), and splits a
`dc:creator` on commas, so it needs:

- every book of a pack under one series spelling, each with its index;
- authors in natural order ("Tui T. Sutherland", not "Sutherland, Tui T.");
- a title, and an author, that are not swapped or missing.

Only evidence already in the download is used: the files' own metadata, their titles, the
names they had in the torrent, and the book the user picked in Shelfmark. Nothing is looked
up online: the providers Shelfmark ships return English series names, or the wrong book,
for French titles. When the evidence does not agree, the file is left as it is.

A non-zero exit fails the whole download in Shelfmark, so every problem is reported on
stdout and the script always exits 0. Hardlinked files are skipped: they are the seeding
torrent's own bytes.
"""

import contextlib
import hashlib
import json
import os
import re
import shutil
import sys
import unicodedata
import zipfile
from collections import Counter
from pathlib import Path
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

OPF_NS = "http://www.idpf.org/2007/opf"
DC_NS = "http://purl.org/dc/elements/1.1/"
CONTAINER_NS = "urn:oasis:names:tc:opendocument:xmlns:container"

ARTICLE = r"(?:les|le|la|l|the)"
SEPARATORS = r"[\s,.(\[_\-\u2013:]*"
MARKER = r"(?:(?:tome|vol(?:ume)?|livre|book|no|n|t)[\s.\u00b0#_\-]*)?"
TRAILING = r"[\s)\]_.,:\-\u2013]*"

META_RE = re.compile(r"<(?:\w+:)?meta\b(?P<attrs>[^>]*?)(?:/>|>(?P<body>.*?)</(?:\w+:)?meta\s*>)", re.S)
TITLE_RE = re.compile(r"(<dc:title\b[^>]*>)(.*?)(</dc:title\s*>)", re.S)
CREATOR_RE = re.compile(r"<dc:creator\b(?P<attrs>[^>]*?)(?:/>|>(?P<body>.*?)</dc:creator\s*>)", re.S)
METADATA_RE = re.compile(r"(<(?:\w+:)?metadata\b[^>]*>)(.*?)(</(?:\w+:)?metadata\s*>)", re.S)


def say(message):
    print(f"epub-metadata: {message}", flush=True)


def fold_char(char):
    base = next((c for c in unicodedata.normalize("NFKD", char) if not unicodedata.combining(c)), char)
    return base.casefold()[:1] or char


def fold(text):
    """Accent- and case-insensitive copy of `text`, one character per character, so match
    offsets in the folded copy slice the original."""
    return "".join(fold_char(c) for c in text or "")


def key(text):
    return " ".join(re.findall(r"[a-z0-9]+", fold(text)))


def series_key(name):
    return re.sub(rf"^{ARTICLE} ", "", key(name))


def attr(attrs, name):
    match = re.search(r"\b" + re.escape(name) + r'\s*=\s*"([^"]*)"', attrs)
    return match.group(1) if match else None


def index_text(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number < 0:
        return None
    return str(int(number)) if number.is_integer() else str(number)


def series_after_name(series, text):
    """Index and remaining text when `text` starts with `series` (case, accents and a
    leading article ignored) followed by a number, e.g. "Les Royaumes de Feu T2 - Titre"."""
    words = series_key(series).split()
    if not words or not text:
        return None, None
    name = r"\W+".join(re.escape(w) for w in words)
    folded = fold(text)
    match = re.search(rf"(?:^|\W)(?:{ARTICLE}\W+)?{name}(?![a-z0-9]){SEPARATORS}{MARKER}0*(\d{{1,3}})(?!\d)", folded)
    if match:
        rest = re.sub(rf"^{TRAILING}", "", text[match.end():])
        return str(int(match.group(1))), rest.strip() or None
    match = re.match(rf"^\W*(?:{ARTICLE}\W+)?{name}\s*[\-\u2013:]\s*(?=\S)", folded)
    if match:
        return None, text[match.end():].strip() or None
    return None, None


class Epub:
    def __init__(self, path):
        self.path = path
        with zipfile.ZipFile(path) as archive:
            container = ET.fromstring(archive.read("META-INF/container.xml"))
            self.opf_name = container.find(f".//{{{CONTAINER_NS}}}rootfile").get("full-path")
            raw = archive.read(self.opf_name)
        self.text = raw.decode("utf-8-sig")
        declaration = re.match(r"<\?xml[^>]*\?>", self.text)
        if declaration and re.search(r"encoding=[\"'](?!utf-8)", declaration.group(0), re.I):
            raise ValueError("OPF is not UTF-8")
        package = ET.fromstring(self.text.encode("utf-8"))
        self.epub3 = package.get("version", "").startswith("3")
        metadata = package.find(f"{{{OPF_NS}}}metadata")
        title = metadata.find(f"{{{DC_NS}}}title")
        self.title = (title.text or "").strip() if title is not None else ""
        self.creators = [(c.text or "").strip() for c in metadata.findall(f"{{{DC_NS}}}creator")]
        metas = {}
        for meta in metadata.iter():
            if meta.tag.endswith("}meta"):
                value = (meta.get("content") or meta.text or "").strip()
                metas.setdefault(meta.get("name") or meta.get("property"), value)
        self.series = metas.get("calibre:series") or metas.get("belongs-to-collection") or None
        self.index = index_text(metas.get("calibre:series_index") or metas.get("group-position"))
        self.new_title = self.new_series = self.new_index = None
        self.new_creators = None
        self.source_name = None

    @property
    def changed(self):
        return any(v is not None for v in (self.new_title, self.new_series, self.new_creators))


def natural_order(name):
    last, sep, first = name.partition(",")
    if not sep or "," in first or not last.strip() or not first.strip():
        return None
    return f"{first.strip()} {last.strip()}"


def fix_people(book, task_title, task_author, canonical_author):
    if not task_author:
        return
    author_key = key(task_author)
    if (
        len(book.creators) == 1
        and key(book.title) == author_key
        and task_title
        and key(book.creators[0]) == key(task_title)
    ):
        book.new_title, book.new_creators = book.creators[0], [canonical_author]
        return
    if not book.creators:
        book.new_creators = [canonical_author]
        return
    fixed = [canonical_author if key(natural_order(c) or "") == author_key else c for c in book.creators]
    if fixed != book.creators:
        book.new_creators = fixed


def canonical_author(books, task_author):
    author_key = key(task_author)
    spellings = Counter()
    for book in books:
        for creator in book.creators:
            natural = creator if key(creator) == author_key else natural_order(creator)
            if natural and key(natural) == author_key:
                spellings[natural] += 1
    if spellings:
        return spellings.most_common(1)[0][0]
    return task_author


def pick_series(books, task):
    """The series the download agrees on: the files' declared series, or Shelfmark's,
    when at least half of the books (and two of them, for a pack) carry it."""
    declared = Counter(series_key(b.series) for b in books if b.series)
    payload_series = task.get("series_name") or None
    if payload_series:
        declared[series_key(payload_series)] += 0
    if not declared:
        return None
    top, _ = declared.most_common(1)[0]
    if len(books) > 1:
        backing = sum(
            1 for b in books
            if (b.series and series_key(b.series) == top)
            or any(series_after_name(name_for(top, books, payload_series), t)[0] for t in (b.title, b.source_name))
        )
        if backing < max(2, (len(books) + 1) // 2):
            return None
    spellings = Counter(b.series for b in books if b.series and series_key(b.series) == top)
    return spellings.most_common(1)[0][0] if spellings else payload_series


def name_for(series_key_value, books, payload_series):
    for book in books:
        if book.series and series_key(book.series) == series_key_value:
            return book.series
    return payload_series or series_key_value


def assign_series(books, series, task):
    proposals = {}
    for book in books:
        index = book.index if book.series and series_key(book.series) == series_key(series) else None
        if index is None and len(books) == 1 and task.get("series_position") is not None:
            index = index_text(task.get("series_position"))
        title_index, rest = series_after_name(series, book.title)
        source_index, source_rest = series_after_name(series, book.source_name)
        index = index or title_index or source_index
        # The torrent's file name only supplies a title the book lacks ("Series, 13"):
        # it is usually an accent-stripped copy of a better one.
        if rest is None and (title_index or not book.title) and source_index == index:
            rest = source_rest
        proposals[book.path] = (index, rest)

    counts = Counter(index for index, _ in proposals.values() if index is not None)
    for book in books:
        index, rest = proposals[book.path]
        if index is None:
            say(f"{book.path.name}: no index for series {series!r}, series left alone")
            continue
        declared_here = book.series and series_key(book.series) == series_key(series) and book.index == index
        if counts[index] > 1 and not declared_here:
            say(f"{book.path.name}: index {index} claimed by several files, series left alone")
            continue
        if book.series != series or book.index != index:
            book.new_series, book.new_index = series, index
        if rest and rest != book.title and book.new_title is None:
            book.new_title = rest


def map_source_names(books, source):
    if not source or not Path(source).is_dir():
        return
    by_size = {}
    for book in books:
        by_size.setdefault(book.path.stat().st_size, []).append(book)
    for candidate in Path(source).rglob("*.epub"):
        matches = by_size.get(candidate.stat().st_size, [])
        if not matches:
            continue
        digest = file_digest(candidate)
        for book in matches:
            if book.source_name is None and file_digest(book.path) == digest:
                book.source_name = candidate.stem
                break


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rewrite_opf(book):
    match = METADATA_RE.search(book.text)
    open_tag, inner, close_tag = match.groups()

    if book.new_title is not None:
        title = TITLE_RE.search(inner)
        if title:
            inner = inner[: title.start(2)] + escape(book.new_title) + inner[title.end(2):]
        else:
            inner = f"\n    <dc:title>{escape(book.new_title)}</dc:title>" + inner
        inner = META_RE.sub(
            lambda m: "" if attr(m.group("attrs"), "name") == "calibre:title_sort" else m.group(0), inner
        )

    if book.new_creators is not None:
        existing = list(CREATOR_RE.finditer(inner))
        for found, name in reversed(list(zip(existing, book.new_creators, strict=False))):
            attrs = re.sub(r'\s+opf:file-as="[^"]*"', "", found.group("attrs")).rstrip("/").rstrip()
            if not book.epub3 and natural_order(name) is None and "," not in name:
                attrs += f" opf:file-as={quoteattr(sort_name(name))}"
            inner = inner[: found.start()] + f"<dc:creator{attrs}>{escape(name)}</dc:creator>" + inner[found.end():]
        for name in book.new_creators[len(existing):]:
            element = (
                f"<dc:creator>{escape(name)}</dc:creator>" if book.epub3
                else f'<dc:creator opf:role="aut" opf:file-as={quoteattr(sort_name(name))}>{escape(name)}</dc:creator>'
            )
            inner = f"\n    {element}" + inner

    if book.new_series is not None:
        collection_refs = {
            "#" + attr(m.group("attrs"), "id") for m in META_RE.finditer(inner)
            if attr(m.group("attrs"), "property") == "belongs-to-collection" and attr(m.group("attrs"), "id")
        }

        def drop_series(m):
            attrs = m.group("attrs")
            if attr(attrs, "name") in ("calibre:series", "calibre:series_index"):
                return ""
            if attr(attrs, "property") in ("belongs-to-collection", "collection-type", "group-position"):
                return ""
            return "" if attr(attrs, "refines") in collection_refs else m.group(0)

        inner = META_RE.sub(drop_series, inner)
        lines = [
            f"<meta name=\"calibre:series\" content={quoteattr(book.new_series)}/>",
            f'<meta name="calibre:series_index" content="{book.new_index}"/>',
        ]
        if book.epub3:
            lines += [
                f'<meta property="belongs-to-collection" id="shelfmark-series">{escape(book.new_series)}</meta>',
                '<meta refines="#shelfmark-series" property="collection-type">series</meta>',
                f'<meta refines="#shelfmark-series" property="group-position">{book.new_index}</meta>',
            ]
        inner = inner.rstrip() + "\n    " + "\n    ".join(lines) + "\n  "

    if not book.epub3 and "opf:" in inner and "xmlns:opf=" not in book.text:
        open_tag = open_tag[:-1] + f' xmlns:opf="{OPF_NS}">'
    return book.text[: match.start()] + open_tag + inner + close_tag + book.text[match.end():]


def sort_name(name):
    first, _, last = name.rpartition(" ")
    return f"{last}, {first}" if first else name


def verify(book, opf_text):
    package = ET.fromstring(opf_text.encode("utf-8"))
    metadata = package.find(f"{{{OPF_NS}}}metadata")
    title = metadata.find(f"{{{DC_NS}}}title")
    creators = [(c.text or "").strip() for c in metadata.findall(f"{{{DC_NS}}}creator")]
    names = {m.get("name"): m.get("content") for m in metadata.iter() if m.tag.endswith("}meta") and m.get("name")}
    if book.new_title is not None and (title is None or title.text != book.new_title):
        raise ValueError("title not written")
    if book.new_creators is not None and creators[: len(book.new_creators)] != book.new_creators:
        raise ValueError(f"creators not written: {creators}")
    if book.new_series is not None and (
        names.get("calibre:series") != book.new_series or names.get("calibre:series_index") != book.new_index
    ):
        raise ValueError("series not written")


def write(book):
    opf_text = rewrite_opf(book)
    verify(book, opf_text)
    temporary = book.path.with_name(book.path.name + ".tmp")
    try:
        with zipfile.ZipFile(book.path) as source, zipfile.ZipFile(temporary, "w") as target:
            if source.read("mimetype").strip() != b"application/epub+zip":
                raise ValueError("not an EPUB mimetype")
            # OCF: mimetype must be the first entry, stored uncompressed.
            entries = sorted(source.infolist(), key=lambda e: e.filename != "mimetype")
            for entry in entries:
                data = opf_text.encode("utf-8") if entry.filename == book.opf_name else source.read(entry.filename)
                copy = zipfile.ZipInfo(entry.filename, date_time=entry.date_time)
                copy.compress_type = zipfile.ZIP_STORED if entry.filename == "mimetype" else entry.compress_type
                copy.external_attr = entry.external_attr
                target.writestr(copy, data)
        with zipfile.ZipFile(temporary) as check:
            if check.testzip() is not None:
                raise ValueError("rewritten archive is corrupt")
        shutil.copymode(book.path, temporary)
        os.replace(temporary, book.path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def describe(book):
    changes = []
    if book.new_series is not None:
        changes.append(f"series {book.new_series!r} #{book.new_index}")
    if book.new_title is not None:
        changes.append(f"title {book.new_title!r}")
    if book.new_creators is not None:
        changes.append(f"authors {book.new_creators}")
    return ", ".join(changes)


def load_books(payload):
    task = payload.get("task") or {}
    if "audiobook" in str(task.get("content_type") or "").lower():
        return []
    books = []
    for raw in (payload.get("paths") or {}).get("final_paths") or []:
        path = Path(raw)
        if path.suffix.lower() != ".epub" or not path.is_file():
            continue
        if path.stat().st_nlink > 1:
            say(f"{path.name}: hardlinked to the torrent's data, left alone")
            continue
        try:
            books.append(Epub(path))
        except (KeyError, ValueError, zipfile.BadZipFile, ET.ParseError, AttributeError) as error:
            say(f"{path.name}: unreadable metadata ({error}), left alone")
    return books


def enrich(payload):
    task = payload.get("task") or {}
    books = load_books(payload)
    if not books:
        return
    if len(books) > 1:
        map_source_names(books, task.get("original_download_path"))

    author = task.get("author") or ""
    if author:
        name = canonical_author(books, author)
        for book in books:
            fix_people(book, task.get("title") or "", author, name)

    series = pick_series(books, task)
    if series:
        assign_series(books, series, task)

    for book in books:
        if not book.changed:
            continue
        try:
            write(book)
            say(f"{book.path.name}: {describe(book)}")
        except (OSError, ValueError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
            say(f"{book.path.name}: not rewritten ({error})")


def main():
    raw = "" if sys.stdin.isatty() else sys.stdin.read()
    if not raw.strip():
        say("no JSON payload; set CUSTOM_SCRIPT_JSON_PAYLOAD=true")
        return
    try:
        enrich(json.loads(raw))
    except Exception as error:
        # Broad on purpose: any exception escaping here fails the user's download.
        say(f"skipped: {type(error).__name__}: {error}")


if __name__ == "__main__":
    main()

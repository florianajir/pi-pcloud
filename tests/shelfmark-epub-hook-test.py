#!/usr/bin/env python3
"""Runs config/shelfmark/epub-metadata-hook.py the way Shelfmark does, on synthetic EPUBs
shaped like the real downloads it was written for, and checks what Kavita will read."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "config" / "shelfmark" / "epub-metadata-hook.py"
OPF_NS = "http://www.idpf.org/2007/opf"
DC_NS = "http://purl.org/dc/elements/1.1/"
CONTAINER = (
    '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
    "</container>"
)
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"  FAIL {message}")


def make_epub(path, title, creators=(), series=None, index=None, collection=None, epub3=False, mimetype_last=False):
    metas = []
    if series:
        metas += [
            f'<meta name="calibre:series" content="{series}"/>',
            f'<meta name="calibre:series_index" content="{index}"/>',
        ]
    if collection:
        metas += [
            f'<meta property="belongs-to-collection" id="c1">{collection[0]}</meta>',
            '<meta refines="#c1" property="collection-type">series</meta>',
            f'<meta refines="#c1" property="group-position">{collection[1]}</meta>',
        ]
    people = "".join(
        f"<dc:creator>{c}</dc:creator>" if epub3 else f'<dc:creator opf:role="aut" opf:file-as="{c}">{c}</dc:creator>'
        for c in creators
    )
    opf = (
        f'<?xml version="1.0" encoding="utf-8"?><package xmlns="{OPF_NS}" version="{"3.0" if epub3 else "2.0"}"'
        ' unique-identifier="id">'
        f'<metadata xmlns:dc="{DC_NS}"{"" if epub3 else f" xmlns:opf=" + chr(34) + OPF_NS + chr(34)}>'
        f'<dc:identifier id="id">urn:uuid:{path.stem}</dc:identifier><dc:title>{title}</dc:title>{people}'
        f"<dc:language>fr</dc:language>{''.join(metas)}</metadata>"
        '<manifest><item id="t" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="t"/></spine></package>'
    )
    entries = [("META-INF/container.xml", CONTAINER), ("content.opf", opf), ("text.xhtml", "<html/>")]
    mimetype = ("mimetype", "application/epub+zip")
    entries = [*entries, mimetype] if mimetype_last else [mimetype, *entries]
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in entries:
            archive.writestr(name, data, zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED)


def read(path):
    with zipfile.ZipFile(path) as archive:
        first = archive.infolist()[0]
        metadata = ET.fromstring(archive.read("content.opf")).find(f"{{{OPF_NS}}}metadata")
        valid = archive.testzip() is None and first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED
    names = {}
    for meta in metadata.iter():
        if meta.tag.endswith("}meta"):
            names.setdefault(meta.get("name") or meta.get("property"), meta.get("content") or meta.text)
    return {
        "title": metadata.find(f"{{{DC_NS}}}title").text,
        "creators": [c.text for c in metadata.findall(f"{{{DC_NS}}}creator")],
        "series": names.get("calibre:series"),
        "index": names.get("calibre:series_index"),
        "collection": names.get("belongs-to-collection"),
        "position": names.get("group-position"),
        "valid": valid,
    }


def run(final_paths, title="", author="", content_type="ebook", source=None, raw=None):
    payload = raw if raw is not None else json.dumps({
        "version": 1,
        "phase": "post_transfer",
        "task": {
            "title": title, "author": author, "content_type": content_type,
            "series_name": None, "series_position": None, "original_download_path": source,
        },
        "paths": {"final_paths": [str(p) for p in final_paths]},
    })
    result = subprocess.run([sys.executable, str(HOOK), "target"], input=payload, capture_output=True, text=True)
    check(result.returncode == 0, f"hook exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout


def test_pack(tmp):
    print("pack whose tomes disagree on series, author and title")
    library, source = tmp / "library", tmp / "torrent"
    library.mkdir()
    source.mkdir()
    prefix = "EBOOK KIDS Tui T. Sutherland - Les Royaumes de feu"
    tomes = {
        "a": (
            {"title": "Les Royaumes de Feu - 01 - La Prophétie", "creators": ["Tui T. Sutherland"],
             "series": "Les Royaumes de Feu", "index": "1"},
            f"{prefix} 1 La prophetie",
        ),
        "b": (
            {"title": "Les Royaumes de Feu T2 - La princesse disparue", "creators": ["Sutherland,Tui T."],
             "series": "Les Royaumes de Feu", "index": "2.0"},
            f"{prefix} 2 La princesse disparue",
        ),
        "c": (
            {"title": "Royaumes de Feu - 03 - Au cœur de la jungle", "creators": ["Sutherland, Tui T."],
             "series": "Royaumes de Feu", "index": "3.0", "mimetype_last": True},
            f"{prefix} 3 Au coeur de la jungle",
        ),
        "d": (
            {"title": "Les Royaumes de Feu - La montagne de Jade", "creators": ["Tui T. Sutherland"]},
            f"{prefix} 6 La montagne de jade",
        ),
        "e": (
            {"title": "Les Royaumes de Feu, 13", "creators": ["Tui T. Sutherland"]},
            f"{prefix} 13 Le souffle du mal",
        ),
        "f": (
            {"title": "La Tempête de sable", "creators": ["Tui T. Sutherland"], "epub3": True,
             "collection": ("Les Royaumes de feu", "10")},
            f"{prefix} 10 La tempete de sable",
        ),
        "g": (
            {"title": "Les Royaumes de Feu - La Mission de Péril"},
            f"{prefix} 8 La mission de Peril",
        ),
    }
    paths = {}
    for name, (spec, original) in tomes.items():
        paths[name] = library / f"les royaumes de feu (2012)_{name}.epub"
        make_epub(paths[name], **spec)
        shutil.copy(paths[name], source / f"{original}.epub")

    originals = {f: f.read_bytes() for f in source.iterdir()}
    run(paths.values(), title="les royaumes de feu", author="tui t. sutherland", source=str(source))

    expected = {
        "a": ("1", "La Prophétie"), "b": ("2", "La princesse disparue"), "c": ("3", "Au cœur de la jungle"),
        "d": ("6", "La montagne de Jade"), "e": ("13", "Le souffle du mal"), "f": ("10", "La Tempête de sable"),
        "g": ("8", "La Mission de Péril"),
    }
    for name, (index, title) in expected.items():
        book = read(paths[name])
        check(book["valid"], f"{name}: archive still a valid EPUB with mimetype first")
        check(book["series"] == "Les Royaumes de Feu", f"{name}: series {book['series']!r}")
        check(float(book["index"] or -1) == float(index), f"{name}: index {book['index']!r}, want {index}")
        check(book["title"] == title, f"{name}: title {book['title']!r}, want {title!r}")
        check(book["creators"] == ["Tui T. Sutherland"], f"{name}: creators {book['creators']}")
    tempete = read(paths["f"])
    check((tempete["collection"], tempete["position"]) == ("Les Royaumes de Feu", "10"), "f: EPUB 3 collection pair")
    for original, data in originals.items():
        check(original.read_bytes() == data, f"torrent original {original.name} was modified")


def test_swapped_title_and_author(tmp):
    print("single book with title and author swapped")
    book = tmp / "crise.epub"
    make_epub(book, title="Rene Guenon", creators=["La Crise du Monde moderne"])
    run([book], title="La crise du monde moderne", author="René Guénon")
    got = read(book)
    check(got["title"] == "La Crise du Monde moderne", f"title {got['title']!r}")
    check(got["creators"] == ["René Guénon"], f"creators {got['creators']}")


def test_left_alone(tmp):
    print("files the hook must not touch")
    seeded = tmp / "seeded.epub"
    make_epub(seeded, title="Les Royaumes de Feu, 4", creators=["Sutherland, Tui T."])
    os.link(seeded, tmp / "torrent-copy.epub")
    before = seeded.read_bytes()
    run([seeded], title="Les Royaumes de Feu", author="Tui T. Sutherland")
    check(seeded.read_bytes() == before, "hardlinked file rewritten")

    audio = tmp / "audio.epub"
    make_epub(audio, title="X", creators=["Doe, John"])
    before = audio.read_bytes()
    run([audio], author="John Doe", content_type="audiobook")
    check(audio.read_bytes() == before, "audiobook task rewritten")

    mixed = []
    for i, series in enumerate(["Alpha", "Beta", "Gamma"]):
        mixed.append(tmp / f"mixed-{i}.epub")
        make_epub(mixed[-1], title=f"Livre {i}", creators=["Jane Roe"], series=series, index="1")
    run(mixed, author="Jane Roe")
    check([read(p)["series"] for p in mixed] == ["Alpha", "Beta", "Gamma"], "unrelated pack forced into one series")

    corrupt = tmp / "corrupt.epub"
    corrupt.write_bytes(b"not a zip")
    run([corrupt], author="Jane Roe")
    run([], raw="")
    run([], raw="{not json")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for test in (test_pack, test_swapped_title_and_author, test_left_alone):
            directory = Path(tmp) / test.__name__
            directory.mkdir()
            test(directory)
    if failures:
        print(f"shelfmark-epub-hook-test: {len(failures)} failure(s)")
        sys.exit(1)
    print("shelfmark-epub-hook-test: all passed")


if __name__ == "__main__":
    main()

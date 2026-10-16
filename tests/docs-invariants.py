"""Invariants the published documentation must hold. Run by `make lint`.

- Every relative Markdown link points at a tracked path, and every #anchor at a
  heading that exists. A doc page loses or renames headings whenever it is
  edited, and scripts print `docs/<PAGE>.md#<anchor>` hints that nothing else
  would notice going dead, so those references are checked in every tracked
  file, not only in Markdown.
- No ISO date in prose: a date in a doc is an incident report or a measurement
  that will read as current long after it stopped being true.
- No piracy source named in published prose, nor in a code comment. The
  download services are general-purpose tools; which trackers or shadow
  libraries a user points them at is theirs to choose, and naming them turns a
  tool into a recommendation. Only comments are read in code, so an identifier
  that has to match an upstream definition stays possible.
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GITHUB_BLOB = "https://github.com/florianajir/pi-pcloud/blob/main/"

# A floor, not a non-empty check: a pathspec that half-breaks still matches
# something, and the gate would pass having read two pages.
DOC_PAGE_FLOOR = 10

PROSE = ("README.md", "CONTRIBUTING.md", "AGENTS.md", "docs/", ".github/", ".agents/")
DATED_PROSE = ("README.md", "CONTRIBUTING.md", "docs/")
COMMENTED_SUFFIXES = (".sh", ".py", ".yaml", ".yml", ".conf", ".template", ".toml", ".ini", ".hujson")
COMMENTED_FILES = ("Makefile", "scripts/pi-pcloud")

PIRACY_SOURCES = re.compile(
    r"(?<!\w)("
    r"ygg\w*|torrent9|nyaa|1337x|pirate ?bay|c411|knaben|tr4ker|world-torrent|torrent\[core\]"
    r"|audiobookbay|anna'?s[ -]archive|annas-archive|libgen|library genesis|z-library|getcomics"
    r"|sci-hub|rarbg|eztv|torrentio|mediafusion"
    r")(?!\w)",
    re.IGNORECASE,
)
ISO_DATE = re.compile(r"(?<![\w-])(?:19|20)\d\d-[01]\d-[0-3]\d(?![\w-])")
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"")
INLINE_CODE = re.compile(r"`[^`]*`")
COMMENT = re.compile(r"(?:^|\s)#(.*)$")
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
REFERENCE_LINK = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)")
DOC_REFERENCE = re.compile(r"(?<![\w/.-])(docs/[A-Za-z0-9_-]+\.md)(?:#([A-Za-z0-9_-]+))?")
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.IGNORECASE)

findings = []


def report(category, path, lineno, message):
    findings.append(f"{category}: {path}:{lineno}: {message}")


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, capture_output=True, check=True)
    return [p for p in out.stdout.decode().split("\0") if p]


def read_text(rel):
    try:
        return (REPO / rel).read_text(encoding="utf-8")
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        return None


def prose_lines(text):
    """Yield (lineno, line) outside fenced code blocks."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield lineno, line


def github_slug(heading):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = re.sub(r"<[^>]+>", "", text).lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchor_cache = {}


def anchors(rel):
    if rel not in _anchor_cache:
        found, seen = set(), {}
        for _, line in prose_lines(read_text(rel) or ""):
            found.update(HTML_ANCHOR.findall(line))
            match = HEADING.match(line)
            if not match:
                continue
            slug = github_slug(match.group(1))
            count = seen.get(slug, 0)
            seen[slug] = count + 1
            found.add(slug if count == 0 else f"{slug}-{count}")
        _anchor_cache[rel] = found
    return _anchor_cache[rel]


def check_target(source, lineno, target_path, anchor, tracked, tracked_dirs):
    if target_path not in tracked and target_path not in tracked_dirs:
        report("link", source, lineno, f"{target_path} is not a tracked file or directory")
        return
    if anchor and target_path.endswith(".md") and anchor not in anchors(target_path):
        report("anchor", source, lineno, f"{target_path} has no heading #{anchor}")


def resolve(source, target):
    path, _, anchor = target.partition("#")
    if not path:
        return source, anchor
    if path.startswith("/"):
        return path.lstrip("/"), anchor
    resolved = (REPO / source).parent.joinpath(path).resolve()
    try:
        return str(resolved.relative_to(REPO)), anchor
    except ValueError:
        return path, anchor


def check_markdown_links(rel, text, tracked, tracked_dirs):
    for lineno, line in prose_lines(text):
        bare = INLINE_CODE.sub("", line)
        targets = INLINE_LINK.findall(bare) + REFERENCE_LINK.findall(bare)
        for target in targets:
            if target.startswith(GITHUB_BLOB):
                target = "/" + target[len(GITHUB_BLOB):]
            elif EXTERNAL.match(target):
                continue
            path, anchor = resolve(rel, target)
            check_target(rel, lineno, path, anchor, tracked, tracked_dirs)


def check_doc_references(rel, text, tracked, tracked_dirs):
    for lineno, line in enumerate(text.splitlines(), 1):
        for path, anchor in DOC_REFERENCE.findall(line):
            check_target(rel, lineno, path, anchor, tracked, tracked_dirs)


def check_prose(rel, text):
    published = rel.startswith(PROSE) and rel.endswith((".md", ".yml", ".yaml"))
    dated = rel.startswith(DATED_PROSE) and rel.endswith(".md")
    if not (published or dated):
        return
    for lineno, line in prose_lines(text):
        bare = INLINE_CODE.sub("", line)
        if published:
            for name in PIRACY_SOURCES.findall(bare):
                report("piracy-source", rel, lineno, f"names {name!r}; describe it generically")
        if dated:
            for date in ISO_DATE.findall(bare):
                report("date", rel, lineno, f"{date} in prose; state the current fact instead")


def has_comments(rel):
    name = Path(rel).name
    return rel.endswith(COMMENTED_SUFFIXES) or rel in COMMENTED_FILES or name.startswith("Dockerfile")


def check_comments(rel, text):
    if rel.startswith(PROSE) or not has_comments(rel):
        return
    for lineno, line in enumerate(text.splitlines(), 1):
        comment = COMMENT.search(line)
        if not comment:
            continue
        for name in PIRACY_SOURCES.findall(comment.group(1)):
            report("piracy-source", rel, lineno, f"comment names {name!r}; describe it generically")


def main():
    tracked = set(tracked_files())
    tracked_dirs = {str(parent) for path in tracked for parent in Path(path).parents if str(parent) != "."}
    pages = [p for p in tracked if p.startswith("docs/") and p.endswith(".md")]
    if len(pages) < DOC_PAGE_FLOOR:
        print(f"floor: only {len(pages)} doc pages matched, expected at least {DOC_PAGE_FLOOR}")
        return 1
    for rel in sorted(tracked):
        if rel == "tests/docs-invariants.py":
            continue
        text = read_text(rel)
        if text is None:
            continue
        if rel.endswith(".md") or rel.startswith(".github/ISSUE_TEMPLATE/"):
            check_markdown_links(rel, text, tracked, tracked_dirs)
        check_doc_references(rel, text, tracked, tracked_dirs)
        check_prose(rel, text)
        check_comments(rel, text)
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Interactive picker for the optional services of the stack.

Usage: services-picker.py <rows-file> <out-file> [ceilings] [held] [peak]

The rows file holds one service per line, as
"service:section:companion-of:needs:conflicts-with:ram-mib:held-mib:peak-mib:state:description",
as produced by scripts/services.sh (which owns everything else: reading
compose/*.yaml, writing .env, running the per-service hooks). This script only
lets the user choose, then writes the services that stay ticked to the out
file, one per line. Exit status is 0 on confirm, 1 on cancel.

held and peak are what scripts/ram-usage.sh last recorded for the service on
this host, 0 for one it has never run. They are why the screen can say anything
at all about an unticked box: a ceiling is what a service may take, and until
it has run here once, nobody knows what it does take.

The last three arguments are the same three figures for the services this
screen never lists, because they run whatever is picked (Traefik, Authelia,
Postgres …); they are the floor every total starts from. Left out, every total
is short by exactly them, so services.sh always passes them; the memory display
goes away altogether only when the rows carry no figures either.

Files rather than stdio: curses owns the terminal, so a captured stdout would
either swallow the UI or the result.

Three relations reach us, and they are deliberately different. `companion-of` is
"pointless on its own" -- aiostreams only makes sense with stremio, n8n-runners with
n8n -- and is drawn as an indented row. `needs` is "cannot run without", which
crosses sections: qbittorrent is a download service listed under Download, but
it runs inside gluetun's network namespace. `conflicts-with` is the opposite:
stremio and stremio-lan are one server in two networking modes and cannot both
run. Toggling propagates along all three, transitively, so the screen always
shows a set the stack can actually run.
"""

import curses
import sys

HELP = "space toggle · a all · n none · enter apply · q cancel"
# Title and the count line. layout() adds one row per memory line it has
# something to draw on: the ceilings, then what was measured here.
HEADER = 2
# Width of the memory column, which holds "2.5G" and "512M" alike - and
# "329M/1.0G" once the service has run here and the cell can carry both.
RAM_WIDTH = 9

# What the memory numbers mean, and why the bar sits where it does.
#
# They are mem_limit ceilings, not measured usage: the stack ships
# overcommitted on purpose (docs/ARCHITECTURE.md, "Rationing CPU and memory").
# The reference 16 GB host carries the full stack at 2.3x its RAM and sits near
# 20% of the ceilings at idle, because a limit is what a service may take when
# it misbehaves, not what it holds. Colouring anything over 1x red would
# therefore flag the shipped default, which is how a warning stops being read.
# Green means the selection fits even if everything peaked at once; amber is the
# ordinary overcommitted stack; red is past what the machine this was tuned for
# was ever asked to carry.
FITS_RATIO = 1.0
OVER_RATIO = 2.5
# A single service worth this much of the host is what to untick first, which is
# a share rather than a fixed size: 1 GB is a rounding error on 16 GB and a
# quarter of a 4 GB Pi. Graded on the peak once there is one - the ceiling grades
# what the stack allows, the peak what this host has actually been asked to find,
# and llama-cpp is heavy by both while stremio-lan is only heavy by the first.
HEAVY_RATIO = 0.25
NOTABLE_RATIO = 0.10


def read_rows(path):
    """Rows in display order, as dicts."""
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":", 9)
            if len(fields) != 10:
                sys.exit(f"services-picker: malformed row {line!r}")
            (service, section, parent, needs, excludes, ram, held, peak, state,
             description) = fields
            rows.append({
                "service": service,
                "section": section,
                "parent": parent,
                # Everything this service cannot run without, companion included.
                "needs": [n for n in ([parent] if parent else []) + needs.split() if n],
                # Everything it can never run alongside. Stated on both sides by
                # services.sh, so this side never has to look for the other.
                "excludes": excludes.split(),
                # mem_limit in MiB, 0 for a service declaring none (which
                # tests/compose-invariants.py refuses, so: never, in practice).
                "ram": int(ram) if ram.isdigit() else 0,
                # Measured on this host, 0 for a service it has never run.
                "held": int(held) if held.isdigit() else 0,
                "peak": int(peak) if peak.isdigit() else 0,
                "on": state == "on",
                "description": description,
            })
    return rows


def build_lines(rows):
    """Display lines: ("head", section) or ("svc", row index)."""
    lines = []
    section = None
    for index, row in enumerate(rows):
        if row["section"] and row["section"] != section:
            section = row["section"]
            lines.append(("head", section))
        lines.append(("svc", index))
    return lines


def index_of(rows, service):
    for index, row in enumerate(rows):
        if row["service"] == service:
            return index
    return None


def need_met(rows, service):
    """True if a needed service is ticked, or something standing in for it is.

    A conflicts-with pair is one service in two modes, so whatever needs one
    mode is served by the other: aiostreams is a stremio addon and runs against
    stremio or stremio-lan indifferently (compose/compose-media.yaml gives stremio-lan its own
    extra_hosts entry for exactly that). Without this, aiostreams' companion-of
    would make it a hard dependant of the VPN mode alone, and the picker would
    be the one place unable to express a setup the rest of the stack supports.
    """
    index = index_of(rows, service)
    if index is None:
        return True
    for candidate in [service] + rows[index]["excludes"]:
        target = index_of(rows, candidate)
        if target is not None and rows[target]["on"]:
            return True
    return False


def satisfied(rows, row):
    """True if everything this service cannot run without is covered."""
    return all(need_met(rows, service) for service in row["needs"])


def turn_off(rows, index, moved):
    """Untick one row and everything left without what it cannot run without."""
    rows[index]["on"] = False
    dropping = True
    while dropping:
        dropping = False
        for row in rows:
            if row["on"] and not satisfied(rows, row):
                row["on"] = False
                moved.append(row["service"])
                dropping = True


def turn_on(rows, index, moved):
    """Tick one row and everything it cannot run without."""
    rows[index]["on"] = True
    pending = [index]
    while pending:
        for service in rows[pending.pop()]["needs"]:
            if need_met(rows, service):
                continue
            target = index_of(rows, service)
            if target is not None:
                rows[target]["on"] = True
                moved.append(service)
                pending.append(target)


def drop_conflicts(rows, ticked, moved):
    """Untick whatever the just-ticked services can never run alongside.

    The newest choice wins: ticking stremio-lan is how you switch to it, so it
    is the already-ticked stremio that goes, along with anything needing it.
    """
    for service in ticked:
        index = index_of(rows, service)
        # A row a previous pass already dropped no longer gets to drop anything:
        # otherwise the two halves of a pair would cancel each other out.
        if index is None or not rows[index]["on"]:
            continue
        for other in rows[index]["excludes"]:
            target = index_of(rows, other)
            if target is not None and rows[target]["on"]:
                moved.append(other)
                turn_off(rows, target, moved)


def toggle(rows, index):
    """Flip one box and carry along whatever cannot run beside it.

    Ticking pulls in everything the service needs; unticking drops everything
    that needs it. Both walk the graph, so aiostreams pulls in stremio and gluetun,
    and dropping gluetun drops stremio and aiostreams with it. Ticking also drops
    the services it conflicts with, since the stack refuses to start with both.
    """
    on = not rows[index]["on"]
    added = []
    removed = []
    if on:
        turn_on(rows, index, added)
        drop_conflicts(rows, [rows[index]["service"], *added], removed)
        # Whatever the conflict took back down was not really added.
        added = [service for service in added if rows[index_of(rows, service)]["on"]]
    else:
        turn_off(rows, index, removed)
    parts = []
    if added:
        parts.append(f"also ticked: {' '.join(sorted(set(added)))}")
    if removed:
        verb = "unticked (conflict)" if on else "also unticked"
        parts.append(f"{verb}: {' '.join(sorted(set(removed)))}")
    return " · ".join(parts)


def set_all(rows, on):
    """Tick or untick every box, minus the pairs that cannot run together.

    Ticking literally everything would select both networking modes of a
    service that has a single data volume, which the stack refuses to start;
    the first of each conflicting pair in display order keeps its box.
    """
    for row in rows:
        row["on"] = on
    if not on:
        return ""
    skipped = []
    drop_conflicts(rows, [row["service"] for row in rows], skipped)
    if not skipped:
        return ""
    return f"left unticked (conflict): {' '.join(sorted(set(skipped)))}"


def name_column(rows):
    """Width of the service column, so the descriptions line up."""
    return max(len(("  " if row["parent"] else "") + row["service"]) for row in rows)


def host_ram_mib():
    """RAM of this host in MiB, 0 when it cannot be read (no /proc)."""
    try:
        with open("/proc/meminfo") as handle:
            for line in handle:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except (OSError, IndexError, ValueError):
        pass
    return 0


def human(mib):
    """A ceiling as it is printed: "512M", "2.5G", nothing at all for none."""
    if not mib:
        return ""
    return f"{mib / 1024:.1f}G" if mib >= 1024 else f"{mib}M"


def ram_line(rows, view):
    """The memory header — worst case for the ticked set — and its colour."""
    total = view["base"] + sum(row["ram"] for row in rows if row["on"])
    ram = view["ram"]
    if not ram:
        return f"RAM ceilings {human(total)}, always-on services included", "ok"
    ratio = total / ram
    if ratio <= FITS_RATIO:
        key, verdict = "ok", "fits even if all peak"
    elif ratio <= OVER_RATIO:
        key, verdict = "warn", "overcommitted, as designed"
    else:
        key, verdict = "over", "too much for this host"
    return f"RAM ceilings {human(total)} of {human(ram)} · {ratio:.1f}x — {verdict}", key


def ram_cell(row):
    """The memory column: what the service holds here over what it may take.

    Just the ceiling for one this host has never run, in the same width and the
    same place, so the column still scans as one thing.
    """
    ceiling = human(row["ram"])
    if not row["held"] or not ceiling:
        return ceiling or human(row["held"])
    return f"{human(row['held'])}/{ceiling}"


def measured_line(rows, view):
    """What the ticked set has actually been measured at, or None.

    Separate from ram_line rather than folded into it, because it answers a
    different question and is allowed to be incomplete: a service nobody has
    ever run here contributes nothing to either total, and saying how many of
    those there are is more honest than quietly leaving them out.
    """
    held = view["base_held"] + sum(row["held"] for row in rows if row["on"])
    peak = view["base_peak"] + sum(row["peak"] for row in rows if row["on"])
    if not peak:
        return None
    unknown = sum(1 for row in rows if row["on"] and not row["peak"])
    text = f"measured here {human(held)} held, {human(peak)} at their peaks"
    if unknown:
        text += f" · {unknown} never run here"
    return text


def ram_key(mib, ram):
    """Colour for one service, by the share of the host it could claim."""
    if not ram or not mib:
        return None
    if mib >= HEAVY_RATIO * ram:
        return "over"
    if mib >= NOTABLE_RATIO * ram:
        return "warn"
    return None


def row_key(row, ram):
    """Which figure a row is graded on: the peak once this host has one.

    The ceiling grades what the stack allows, the peak what the machine has
    actually been asked to find - and they disagree in both directions.
    stremio-lan is allowed 1 GB and has never held more than 113 MB, while
    llama-cpp is allowed 6 GB and has taken every byte of it.
    """
    return ram_key(row["peak"] or row["ram"], ram)


def color_keys():
    """Colour pair per key, every one of them plain on a terminal without."""
    keys = {"ok": curses.A_NORMAL, "warn": curses.A_NORMAL, "over": curses.A_NORMAL}
    if not curses.has_colors():
        return keys
    try:
        curses.use_default_colors()
        background = -1
    except curses.error:
        background = curses.COLOR_BLACK
    palette = (("ok", curses.COLOR_GREEN), ("warn", curses.COLOR_YELLOW),
               ("over", curses.COLOR_RED))
    for index, (key, color) in enumerate(palette, start=1):
        curses.init_pair(index, color, background)
        keys[key] = curses.color_pair(index)
    return keys


def layout(rows, base, base_held, base_peak):
    """What the drawing needs that no keypress changes.

    The memory column appears only when the rows carry ceilings, the ceiling
    header only when there is a total worth printing, and the measured header
    only once something has been measured — so a caller that passes none of
    them gets exactly the screen this picker drew before they existed, and a
    host that has never run the stack gets the ceilings alone.
    """
    column_ram = any(row["ram"] for row in rows)
    header_ram = column_ram or base > 0
    header_measured = base_peak > 0 or any(row["peak"] for row in rows)
    return {
        "column": name_column(rows),
        "base": base,
        "base_held": base_held,
        "base_peak": base_peak,
        "ram": host_ram_mib(),
        "column_ram": column_ram,
        "header_ram": header_ram,
        "header_measured": header_measured,
        "header": HEADER + (1 if header_ram else 0) + (1 if header_measured else 0),
        "colors": color_keys(),
    }


def draw(win, rows, lines, cursor, offset, message, view):
    win.erase()
    height, width = win.getmaxyx()
    head = view["header"]
    body = max(height - head - 1, 1)
    enabled = sum(1 for row in rows if row["on"])
    # Lines that fit 80 columns: what this screen does, what it will not touch —
    # the services missing from the list on purpose — and what the ticked ones
    # could take between them.
    win.addnstr(0, 0, "Choose which services run — applying starts and stops containers now",
                width - 1, curses.A_BOLD)
    win.addnstr(1, 0, f"{enabled}/{len(rows)} enabled · Traefik, Authelia, Pi-hole, "
                      f"Headscale, Postgres … always run", width - 1, curses.A_DIM)
    line_y = HEADER
    if view["header_ram"] and height > line_y:
        text, key = ram_line(rows, view)
        win.addnstr(line_y, 0, text, width - 1, view["colors"][key] | curses.A_BOLD)
        line_y += 1
    if view["header_measured"] and height > line_y:
        # Dim, and under the ceilings rather than over them: the ceilings are
        # what a tick changes, this is what the host has to say about it.
        text = measured_line(rows, view)
        if text:
            win.addnstr(line_y, 0, text, width - 1, curses.A_DIM)
    column = view["column"]
    ram_x = 5 + column + 1
    ram_width = RAM_WIDTH if view["column_ram"] else 0
    # Descriptions only earn their place once the names fit comfortably.
    room = width - (ram_x + ram_width + 2)
    for screen_row, line_index in enumerate(range(offset, min(offset + body, len(lines)))):
        kind, payload = lines[line_index]
        y = screen_row + head
        # `body` has a floor of one row, so a window too short to hold the
        # header and the footer would otherwise be written past its last line -
        # curses raises there, and the picker dies with a traceback instead of
        # drawing what fits.
        if y >= height - 1:
            break
        if kind == "head":
            win.addnstr(y, 0, f"── {payload} ".ljust(width - 1, "─"), width - 1, curses.A_DIM)
            continue
        row = rows[payload]
        name = ("  " if row["parent"] else "") + row["service"]
        text = f" [{'x' if row['on'] else ' '}] {name}"
        ram = ram_cell(row).rjust(ram_width) if ram_width else ""
        text = text.ljust(ram_x) + ram
        if row["description"] and room >= 16:
            text = f"{text.ljust(ram_x + ram_width + 2)}{row['description']}"
        attr = curses.A_REVERSE if line_index == cursor else curses.A_NORMAL
        win.addnstr(y, 0, text.ljust(width - 1), width - 1, attr)
        # Drawn again on its own, so the ceiling carries the colour without the
        # name and the description taking it with them.
        key = row_key(row, view["ram"]) if ram_width else None
        if key and ram_x + ram_width < width:
            win.addnstr(y, ram_x, ram, ram_width, view["colors"][key] | attr)
    win.addnstr(height - 1, 0, (message or HELP)[:width - 1], width - 1, curses.A_DIM)
    win.refresh()


def first_service_line(lines, start, step):
    """Nearest line at or after start (walking by step) that is a service."""
    index = start
    while 0 <= index < len(lines):
        if lines[index][0] == "svc":
            return index
        index += step
    return None


def move(lines, cursor, start, step):
    """Cursor after a move, staying on a service line and inside the list."""
    target = first_service_line(lines, start, step)
    return cursor if target is None else target


def run(screen, rows, base, base_held, base_peak):
    curses.curs_set(0)
    lines = build_lines(rows)
    cursor = first_service_line(lines, 0, 1)
    if cursor is None:
        return False
    offset = 0
    message = ""
    view = layout(rows, base, base_held, base_peak)
    while True:
        height = max(screen.getmaxyx()[0] - view["header"] - 1, 1)
        offset = min(offset, cursor)
        if cursor >= offset + height:
            offset = cursor - height + 1
        draw(screen, rows, lines, cursor, offset, message, view)
        key = screen.getch()
        if key in (ord("q"), 27):
            return False
        if key in (curses.KEY_ENTER, 10, 13):
            return True
        message = ""
        if key in (curses.KEY_DOWN, ord("j")):
            cursor = move(lines, cursor, cursor + 1, 1)
        elif key in (curses.KEY_UP, ord("k")):
            cursor = move(lines, cursor, cursor - 1, -1)
        elif key == curses.KEY_NPAGE:
            cursor = move(lines, cursor, min(cursor + height, len(lines) - 1), -1)
        elif key == curses.KEY_PPAGE:
            cursor = move(lines, cursor, max(cursor - height, 0), 1)
        elif key == ord(" "):
            message = toggle(rows, lines[cursor][1])
        elif key == ord("a"):
            message = set_all(rows, True)
        elif key == ord("n"):
            message = set_all(rows, False)
        elif key == curses.KEY_RESIZE:
            offset = 0


def main():
    if not 3 <= len(sys.argv) <= 6:
        print("usage: services-picker.py <rows-file> <out-file> "
              "[ceilings] [held] [peak]", file=sys.stderr)
        return 2
    rows = read_rows(sys.argv[1])
    if not rows:
        print("services-picker: no services to choose from", file=sys.stderr)
        return 2

    def figure(position):
        value = sys.argv[position] if len(sys.argv) > position else ""
        return int(value) if value.isdigit() else 0

    if not curses.wrapper(run, rows, figure(3), figure(4), figure(5)):
        return 1
    with open(sys.argv[2], "w") as handle:
        for row in rows:
            if row["on"]:
                handle.write(row["service"] + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

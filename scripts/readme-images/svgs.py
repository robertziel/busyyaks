#!/usr/bin/env python3
"""The README SVGs of busyyaks and of the kanban module. The diagrams take the look of the article "How I reached 100
quality PRs a day with an agents kanban" (a light paper plate with a hairline border, ink text, a maroon accent for the
agent side) and read on GitHub's light and dark themes because they carry that plate. The module's logo is a
transparent Light + Dark pair, swapped by the README's <picture> (prefers-color-scheme), like busyyaks's own
public/static/logo-{light,dark}.svg. Every file is self-contained — no external font, CSS, variable or script (GitHub
sanitises SVGs).

    docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/w -v <module checkout>:/module -w /w python:3.13-slim \
        python scripts/readme-images/svgs.py /module [<article page.html>]

writes docs/images/architecture.svg (How it works) and /module/docs/images/logo-{light,dark}.svg (the module's: the
busyyaks logo beside a kanban glyph and the words "kanban module"). With the article's saved HTML
also docs/images/agency.svg: its agency-structure figure (svg aria-labelledby="org-w"), its classes resolved to the
article's colours.
"""
import os
import re
import sys

# the article's palette (its :root custom properties)
PAPER = "#fbfaf9"  # --paper-light: the plate
RULE = "#ded7d6"  # --rule: the plate's border, human boxes
INK = "#191416"  # --ink
INK_SOFT = "#453e40"  # --ink-soft
INK_FAINT = "#6d6567"  # --ink-faint
ACCENT = "#7a2733"  # --accent
FONT = "Outfit, Futura, 'Century Gothic', 'Segoe UI', Helvetica, Arial, sans-serif"
# the article's diagram classes → presentation attributes
CLASSES = {
    "fill-strong": 'fill="#191416"',
    "fill-body": 'fill="#191416"',
    "fill-muted": 'fill="#453e40"',
    "fill-dim": 'fill="#6d6567"',
    "fill-accent": 'fill="#7a2733"',
    "fill-amber": 'fill="#a06c14"',
    "fill-bg": 'fill="#f6f4f3"',
    "fill-surface": 'fill="#14294d" fill-opacity=".045"',
    "fill-accent-tint": 'fill="#7a2733" fill-opacity=".1"',
    "fill-accent-tint-strong": 'fill="#7a2733" fill-opacity=".17"',
    "fill-muted-tint": 'fill="#5b6a80" fill-opacity=".1"',
    "stroke-accent": 'stroke="#7a2733"',
    "stroke-amber": 'stroke="#a06c14"',
    "stroke-bg": 'stroke="#f6f4f3"',
    "stroke-rule": 'stroke="#ded7d6"',
    "stroke-rule-faint": 'stroke="#5b6a80" stroke-opacity=".13"',
    "stroke-rule-soft": 'stroke="#eae4e3"',
    "stroke-muted-rule": 'stroke="#5b6a80" stroke-opacity=".26"',
}
# busyyaks's palette (scripts/logo/build.py SKINS): ink, accent per skin; the logos stay in the brand's colours
SKINS = {"light": ("#16181D", "#C2410C"), "dark": ("#ECEEF2", "#FF8A3D")}
LOGO_FONT = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif"  # busyyaks's UI type, as its wordmark


def plate(w, h, body, label, title=None):
    t = f"<title>{title}</title>" if title else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{label}" font-family="{FONT}">{t}'
        f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="10" fill="{PAPER}" stroke="{RULE}"/>{body}</svg>\n'
    )


def busyyaks_logo(checkout, skin):
    with open(os.path.join(checkout, "public/static", f"logo-{skin}.svg")) as f:
        svg = f.read().strip()
    m = re.match(r'<svg [^>]*viewBox="([^"]+)"[^>]*>', svg)
    if not m:
        sys.exit(f"svgs.py: no viewBox in public/static/logo-{skin}.svg")
    return m.group(1), svg[m.end():-len("</svg>")]


def kanban_glyph(ink, accent):
    """Three columns (outlined), cards in the accent: 2, 3 and 1 of them."""
    out = []
    for i, n in enumerate((2, 3, 1)):
        x = i * 60
        out.append(f'<rect x="{x}" y="0" width="52" height="150" rx="10" fill="none" stroke="{ink}" stroke-width="5"/>')
        for j in range(n):
            out.append(f'<rect x="{x + 9}" y="{12 + j * 32}" width="34" height="23" rx="5" fill="{accent}"/>')
    return "".join(out)


def module_logo(checkout, skin):
    """Transparent, in the skin's ink and accent: the README swaps Light and Dark with <picture>."""
    ink, accent = SKINS[skin]
    vb, inner = busyyaks_logo(checkout, skin)
    w, h = 1250, 230
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="busyyaks kanban module">'
        f'<svg x="0" y="0" width="680" height="{h}" viewBox="{vb}" preserveAspectRatio="xMinYMid meet">{inner}</svg>'
        f'<g transform="translate(712 42)">{kanban_glyph(ink, accent)}</g>'
        f'<text x="912" y="118" font-family="{LOGO_FONT}" font-size="76" font-weight="700" fill="{ink}">kanban</text>'
        f'<text x="914" y="180" font-family="{LOGO_FONT}" font-size="54" font-weight="600" fill="{accent}">module</text>'
        "</svg>\n"
    )


def agency(page):
    html = open(page).read()
    i = html.index('aria-labelledby="org-w"')
    a = html.rfind("<svg", 0, i)
    svg = html[a:html.index("</svg>", i) + len("</svg>")]
    m = re.match(r'<svg [^>]*viewBox="0 0 (\d+) (\d+)"[^>]*>', svg)
    if not m:
        sys.exit("svgs.py: the agency figure has no 0 0 w h viewBox")
    w, h = int(m.group(1)), int(m.group(2))
    inner = svg[m.end():-len("</svg>")]

    def attrs(mm):
        out = []
        for c in mm.group(1).split():
            if c not in CLASSES:
                sys.exit(f"svgs.py: the agency figure uses class {c}, which has no colour here")
            out.append(CLASSES[c])
        return " ".join(out)

    inner = re.sub(r'class="([^"]*)"', attrs, inner)
    # the figure's <title> names the whole image: it moves to the root, beside the plate
    t = re.search(r"<title[^>]*>(.*?)</title>", inner, re.S)
    if not t:
        sys.exit("svgs.py: the agency figure has no <title>")
    inner = inner[:t.start()] + inner[t.end():]
    if re.search(r"<script|<style|var\(|url\(|href=", inner):
        sys.exit("svgs.py: the agency figure still holds a script, style, variable, url or link")
    # the article draws it on its paper plate: the same plate, the figure as is inside
    return plate(w + 16, h + 16, f'<g transform="translate(8 8)">{inner}</g>',
                 "The agent agency inside a human organisation", t.group(1).strip())


SHARED = 'stroke="#5b6a80" stroke-opacity=".5"'  # used by both sides: the plate's paper, a slate hairline


def box(x, y, w, h, name, sub, agent=False, tint=False, shared=False):
    fill = f'fill="{ACCENT}" fill-opacity=".1"' if tint else 'fill="#14294d" fill-opacity=".045"'
    stroke = f'stroke="{ACCENT if agent else RULE}"'
    if shared:
        fill, stroke = f'fill="{PAPER}"', SHARED
    cx = x + w / 2
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" {fill} {stroke} stroke-width="1.2"/>'
        f'<text x="{cx}" y="{y + h / 2 - 3}" font-size="13.5" font-weight="700" fill="{INK}" text-anchor="middle">{name}</text>'
        f'<text x="{cx}" y="{y + h / 2 + 13}" font-size="11.5" fill="{INK_SOFT}" text-anchor="middle">{sub}</text>'
    )


def arrow(x1, y1, x2, y2, agent=False, dash=False):
    c = ACCENT if agent else INK_FAINT
    d = ' stroke-dasharray="5 4"' if dash else ""
    m = "a" if agent else "h"
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{c}" stroke-width="1.4"{d} marker-end="url(#{m})"/>'


def text(x, y, s, size=12, color=INK_SOFT, weight=None, anchor=None):
    wgt = f' font-weight="{weight}"' if weight else ""
    anc = f' text-anchor="{anchor}"' if anchor else ""
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}"{wgt}{anc}>{s}</text>'


def architecture():
    defs = (
        "<defs>"
        f'<marker id="h" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
        f'<path d="M0 0 L10 5 L0 10 z" fill="{INK_FAINT}"/></marker>'
        f'<marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">'
        f'<path d="M0 0 L10 5 L0 10 z" fill="{ACCENT}"/></marker>'
        "</defs>"
    )
    b = [
        defs,
        text(16, 30, "How it works: the compose services, one database, one launcher on the host", 14, INK, 700),
        text(16, 48, "the operator's browser and the agents' MCP calls reach the same data", 12),
        box(24, 66, 260, 50, "browser (SPA)", "the operator"),
        box(430, 66, 266, 50, "Claude Code sessions (tmux)", "the agents", agent=True),
        arrow(160, 116, 160, 198), text(169, 152, "session cookie", 11.5),
        arrow(593, 116, 593, 198, agent=True), text(584, 152, "bearer MCP_TOKEN", 11.5, ACCENT, anchor="end"),
        f'<rect x="12" y="166" width="692" height="196" rx="8" fill="#5b6a80" fill-opacity=".1" stroke="#5b6a80" '
        'stroke-opacity=".26" stroke-width="1.2" stroke-dasharray="5 4"/>',
        text(26, 187, "docker compose", 12.5, INK, 700),
        box(24, 198, 154, 56, "web", "JSON API + SPA shell"),
        box(188, 198, 154, 56, "scanner", "git log · status · upstream"),
        box(352, 198, 154, 56, "github", "network · feed · PRs"),
        box(516, 198, 176, 56, "mcp", "MCP server, local only", agent=True),
        box(24, 266, 318, 56, "notifier", "types comments + answers into a session · watchdog", agent=True),
        box(352, 266, 340, 56, "database", "data/busyyaks.sqlite3 · or PostgreSQL", shared=True),
        text(26, 344, "every service reads and writes the one database; web, mcp and notifier also call the launcher",
             11.5),
        arrow(511, 362, 511, 404, agent=True), text(500, 388, "unix socket data/run/launcher.sock", 11.5, ACCENT,
                                                    anchor="end"),
        box(352, 404, 340, 56, "bin/launcher (host, systemd --user)", "starts tmux sessions · captures dialogs · clones",
            agent=True, tint=True),
        f'<path d="M692 432 H710 V91 H700" fill="none" stroke="{ACCENT}" stroke-width="1.4" stroke-dasharray="5 4" '
        'marker-end="url(#a)"/>',
        f'<rect x="24" y="418" width="14" height="12" rx="2" fill="#14294d" fill-opacity=".045" stroke="{RULE}" '
        'stroke-width="1.2"/>',
        text(44, 428, "operator side", 12, INK),
        f'<rect x="150" y="418" width="14" height="12" rx="2" fill="#14294d" fill-opacity=".045" stroke="{ACCENT}" '
        'stroke-width="1.2"/>',
        text(170, 428, "agent side", 12, INK),
        f'<rect x="260" y="418" width="14" height="12" rx="2" fill="{PAPER}" {SHARED} stroke-width="1.2"/>',
        text(280, 428, "both", 12, INK),
    ]
    return plate(720, 478, "".join(b), "How busyyaks works",
                 "How busyyaks works: the browser reaches the web container with a session cookie and the Claude Code "
                 "sessions reach the mcp container with a bearer token; web, scanner, github, mcp and notifier run in "
                 "docker compose over one database; a unix socket connects them to bin/launcher on the host, which "
                 "starts the tmux sessions and captures their dialogs.")


def write(path, svg):
    with open(path, "w") as f:
        f.write(svg)
    print(f"{path} {len(svg)} bytes")


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: svgs.py <module checkout> [<article page.html>]")
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    module = sys.argv[1]
    write(os.path.join(repo, "docs/images/architecture.svg"), architecture())
    for skin in SKINS:
        write(os.path.join(module, f"docs/images/logo-{skin}.svg"), module_logo(repo, skin))
    if len(sys.argv) == 3:
        write(os.path.join(repo, "docs/images/agency.svg"), agency(sys.argv[2]))


if __name__ == "__main__":
    main()

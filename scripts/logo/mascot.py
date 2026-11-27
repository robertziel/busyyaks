#!/usr/bin/env python3
"""busyyaks mascot scenes: the loading yak's geometry posed for the pages where something is wrong.

    docker run --rm -v "$PWD":/app -w /app python:3.13-slim python scripts/logo/mascot.py

lost    (404, a card / report / page that is not there): head tilted, a question mark over it, one card on its back.
broken  (an error: a failed read, a page that crashed): the card stack fell off, the cards lie on the ground, head down.
offline (no connection: the device is offline / the server does not answer): the yak's cord is unplugged, sparks.
Geometry = loader.py's (= build.py's) yak. Ink currentColor, accent var(--accent); no ids, so any number per page.
prefers-reduced-motion → still. Writes frontend/src/components/yakMascots.ts (the SPA's <Mascot>).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loader import BODY, CARDS, EAR, FACE, HORNS, BEARD, LEGS, ROOT, TAIL, card_d, n, reduced, rule, ts_string  # noqa: E402

GROUND = '<path d="M{x0} 213H{x1}" stroke="currentColor" stroke-width="3" stroke-linecap="round" opacity=".28"/>'


def legs():
    return "".join(f'<rect x="{x}" y="150" width="26" height="62" rx="9"/>' for x, _ in LEGS)


def head(cls):
    return (f'<g class="{cls}"><path d="{HORNS}"/><path d="{EAR}"/>'
            f'<path fill-rule="evenodd" d="{FACE}"/><path d="{BEARD}"/></g>')


def lying_card(cls, x, y, w, h, t):
    """a card at (x, y) turned t degrees (the loader's card shape: a rounded rect with two text lines cut out)"""
    return (f'<g class="{cls}"><path fill-rule="evenodd" transform="rotate({t} {n(x + w / 2)} {n(y + h / 2)})" '
            f'd="{card_d(x, y, w, h)}"/></g>')


def svg(cls, vb, css, body):
    return f'<svg class="{cls}" viewBox="{vb}" aria-hidden="true" fill="currentColor"><style>{css}</style>{body}</svg>'


# ---- lost: where is that page? ------------------------------------------------------------------------------------
def lost():
    p, T = "ml", 3.2
    q = ('<path d="M292 12c0-16 12-26 27-26s27 10 27 25c0 13-9 19-17 24c-6 4-9 7-9 15" fill="none" '
         'stroke="var(--accent)" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>'
         '<circle cx="320" cy="72" r="7" fill="var(--accent)"/>')
    css = (f"@keyframes {p}-tilt{{0%,100%{{transform:rotate(0)}}20%,45%{{transform:rotate(-9deg)}}65%,85%{{transform:rotate(7deg)}}}}"
           f"@keyframes {p}-q{{0%,100%{{transform:translateY(0) rotate(0)}}25%{{transform:translateY(-6px) rotate(-6deg)}}"
           f"70%{{transform:translateY(-3px) rotate(8deg)}}}}"
           f"@keyframes {p}-tail{{0%,100%{{transform:rotate(0)}}50%{{transform:rotate(14deg)}}}}"
           + rule(f".{p}-head", "10% 60%", f"{p}-tilt", T) + rule(f".{p}-q", "30% 100%", f"{p}-q", T)
           + rule(f".{p}-tail", "100% 80%", f"{p}-tail", T / 2) + reduced(p))
    x, y, w, h, t = CARDS[0]
    body = (GROUND.format(x0=30, x1=300) + legs() + f'<g class="{p}-tail">{TAIL}</g><path d="{BODY}"/>' + head(f"{p}-head")
            + f'<g fill="var(--accent)">{lying_card("", x, y, w, h, t)}</g><g class="{p}-q">{q}</g>')
    return svg(p, "24 -40 340 260", css, body)


# ---- broken: the load fell off ------------------------------------------------------------------------------------
def broken():
    p, T = "mb", 2.4
    ground = [(-34, 186, 100, 26, -14), (244, 192, 84, 22, 14), (70, 74, 90, 24, -24)]  # left, right, the one still sliding
    sparks = ('<g class="{p}-sp" fill="none" stroke="var(--accent)" stroke-width="5" stroke-linecap="round">'
              '<path d="M8 160l-8-14M24 156l4-16M40 164l12-10"/></g>').format(p=p)
    css = (f"@keyframes {p}-droop{{0%,100%{{transform:rotate(14deg)}}50%{{transform:rotate(19deg)}}}}"
           f"@keyframes {p}-slide{{0%,30%{{transform:translate(0,0) rotate(0)}}70%,100%{{transform:translate(-8px,6px) rotate(-6deg)}}}}"
           f"@keyframes {p}-sp{{0%,100%{{opacity:0}}40%,60%{{opacity:1}}}}"
           f"@keyframes {p}-wob{{0%,100%{{transform:rotate(0)}}50%{{transform:rotate(-4deg)}}}}"
           + rule(f".{p}-head", "10% 60%", f"{p}-droop", T) + rule(f".{p}-c3", "100% 100%", f"{p}-slide", T, extra=";animation-direction:alternate")
           + rule(f".{p}-sp", "50% 50%", f"{p}-sp", T / 2) + rule(f".{p}-c1", "50% 100%", f"{p}-wob", T)
           + reduced(p))
    cards = "".join(lying_card(f"{p}-c{k}", *c) for k, c in enumerate(ground, 1))
    body = (GROUND.format(x0=-40, x1=320) + legs() + f'<g>{TAIL}</g><path d="{BODY}"/>' + head(f"{p}-head")
            + f'<g fill="var(--accent)">{cards}</g>' + sparks)
    return svg(p, "-50 -10 380 236", css, body)


# ---- offline: unplugged -------------------------------------------------------------------------------------------
def offline():
    p, T = "mo", 2.0
    cord = ('<path d="M60 150C30 152 20 196 -4 200C-20 203 -32 196 -44 191" fill="none" stroke="currentColor" '
            'stroke-width="7" stroke-linecap="round"/>')
    plug = ('<g class="{p}-plug" fill="var(--accent)"><rect x="-74" y="177" width="32" height="28" rx="7"/>'
            '<rect x="-90" y="181" width="18" height="6" rx="2"/><rect x="-90" y="195" width="18" height="6" rx="2"/></g>').format(p=p)
    socket = ('<g fill="var(--accent)"><path fill-rule="evenodd" d="M-150 164h22a8 8 0 0 1 8 8v32a8 8 0 0 1-8 8h-22Z'
              'M-136 181h12v6h-12ZM-136 195h12v6h-12Z"/></g>')
    sparks = ('<g class="{p}-sp" fill="none" stroke="var(--accent)" stroke-width="4" stroke-linecap="round">'
              '<path d="M-108 170l-4-12M-100 177l8-8M-108 212l-4 10M-100 205l8 8"/></g>').format(p=p)
    css = (f"@keyframes {p}-reach{{0%,100%{{transform:translateX(0)}}45%,55%{{transform:translateX(-12px)}}}}"
           f"@keyframes {p}-sp{{0%,40%,70%,100%{{opacity:0}}50%,60%{{opacity:1}}}}"
           f"@keyframes {p}-look{{0%,100%{{transform:rotate(0)}}50%{{transform:rotate(-5deg)}}}}"
           + rule(f".{p}-plug", "50% 50%", f"{p}-reach", T) + rule(f".{p}-sp", "50% 50%", f"{p}-sp", T)
           + rule(f".{p}-head", "10% 60%", f"{p}-look", T * 2) + reduced(p))
    body = (GROUND.format(x0=-150, x1=300) + cord + legs() + f'<g>{TAIL}</g><path d="{BODY}"/>' + head(f"{p}-head")
            + socket + plug + sparks)
    return svg(p, "-160 30 470 196", css, body)


SCENES = {"lost": lost, "broken": broken, "offline": offline}


def main():
    ts = ["// Generated by scripts/logo/mascot.py — do not edit by hand.",
          'export const YAK_MASCOTS: Record<"lost" | "broken" | "offline", string> = {']
    for key, make in SCENES.items():
        # as Prettier prints it: a key longer than 4 characters with a too-long value moves the value to its own line
        sep = "\n    " if len(key) > 4 else " "
        ts.append(f"  {key}:{sep}{ts_string(make())},")
    ts.append("};")
    with open(os.path.join(ROOT, "frontend", "src", "components", "yakMascots.ts"), "w") as f:
        f.write("\n".join(ts) + "\n")


if __name__ == "__main__":
    main()

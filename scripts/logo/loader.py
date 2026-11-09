#!/usr/bin/env python3
"""busyyaks loading yaks: two animated loaders, picked at random per loading state.

    docker run --rm -v "$PWD":/app -w /app python:3.13-slim python scripts/logo/loader.py

A · Trot (0.8s): walks in place, legs in diagonal pairs, body bobs, head nods, tail wags, cards sway.
B · Haul (1.6s): three cards land on its back one by one, then it tosses the load forward.
Geometry = build.py's yak. No ids (the eye and the card text lines are evenodd holes), so any number per page.
prefers-reduced-motion → still yak. Writes
  frontend/src/components/yakLoaders.ts — ink currentColor, accent var(--accent) (the SPA's <YakLoader>)
  public/static/yak-loader-{a,b}-{light,dark}[-still].svg — fixed skin colours (the vendored board's .spin, via CSS;
    -still = no animation, for prefers-reduced-motion)
"""
import json
import re
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SKINS = {"light": ("#16181d", "#a8380a"), "dark": ("#eceef2", "#ff8a3d")}  # = app.css --ink / --accent per skin
LEGS = [(78, "a"), (112, "b"), (180, "b"), (212, "a")]
BODY = ("M58 146C50 128 58 110 74 104C76 92 92 86 104 90C110 80 126 78 136 84C146 76 162 76 170 84C180 78 196 80 "
        "202 90C212 88 222 96 222 106C232 118 230 136 226 150Q232 168 228 180Q220 170 212 172Q210 186 200 190"
        "Q194 176 186 176Q180 190 170 192Q166 178 156 178Q150 192 140 192Q136 178 126 178Q118 190 108 188"
        "Q106 176 96 174Q88 186 78 182Q80 170 72 166Q62 172 56 166Q60 156 58 146Z")
HORNS = ("M220 100C204 92 198 72 206 58C209 54 214 56 214 61C214 74 222 84 236 90Z"
         "M266 86C280 78 284 64 278 52C280 47 287 49 288 54C294 70 290 88 276 96Z")
EAR = "M216 120C200 112 186 116 182 126C192 132 206 132 218 128Z"
FACE = ("M212 104C210 88 228 78 244 82C258 76 276 82 282 96C294 104 296 122 290 136C292 150 284 164 270 168"
        "C256 176 236 172 226 160C212 156 204 140 208 126C202 118 204 108 212 104Z"
        "M272 124a6 6 0 1 0-12 0a6 6 0 1 0 12 0Z")  # eye = evenodd hole
BEARD = "M230 162Q232 182 242 178Q248 192 256 178Q266 186 268 168Z"
TAIL = ('<path d="M62 136C46 130 40 116 44 102" fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round"/>'
        '<path d="M44 104C32 100 32 84 42 80C44 70 58 70 58 80C66 84 64 98 54 102C52 108 46 108 44 104Z"/>')
CARDS = [(98, 58, 100, 26, -2), (106, 31, 90, 24, 3), (116, 6, 76, 22, -4)]


def n(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def rr(x, y, w, h, r):
    """rounded rect as a path (so evenodd can cut holes in it)"""
    return (f"M{n(x + r)} {n(y)}h{n(w - 2 * r)}a{n(r)} {n(r)} 0 0 1 {n(r)} {n(r)}v{n(h - 2 * r)}a{n(r)} {n(r)} 0 0 1-{n(r)} {n(r)}"
            f"h-{n(w - 2 * r)}a{n(r)} {n(r)} 0 0 1-{n(r)}-{n(r)}v-{n(h - 2 * r)}a{n(r)} {n(r)} 0 0 1 {n(r)}-{n(r)}Z")


def card_d(x, y, w, h):
    return (rr(x, y, w, h, 6) + f"M{n(x + 9)} {n(y + 7)}h{n(w * .55)}v4.5h-{n(w * .55)}Z"
            f"M{n(x + 9)} {n(y + h - 11.5)}h{n(w * .32)}v4.5h-{n(w * .32)}Z")


def card(i, cls=""):
    x, y, w, h, t = CARDS[i]
    inner = f'<path fill-rule="evenodd" transform="rotate({t} {n(x + w / 2)} {n(y + h / 2)})" d="{card_d(x, y, w, h)}"/>'
    return f'<g class="{cls}">{inner}</g>' if cls else inner


def legs(p):
    return "".join(f'<rect class="{p}-l{pair}" x="{x}" y="150" width="26" height="62" rx="9"/>' for x, pair in LEGS)


def head(p=None):
    inner = (f'<path d="{HORNS}"/><path class="{p}-ear" d="{EAR}"/>' if p else f'<path d="{HORNS}"/><path d="{EAR}"/>') + \
            f'<path fill-rule="evenodd" d="{FACE}"/><path d="{BEARD}"/>'
    return inner


def svg(cls, vb, style, body, label):
    return f'<svg class="{cls}" viewBox="{vb}" aria-hidden="true" fill="currentColor"><style>{style}</style>{body}</svg>'


def reduced(p):
    return f"[class^={p}-]{{transform-box:fill-box}}@media (prefers-reduced-motion:reduce){{.{p} *{{animation:none!important}}}}"


def rule(sel, origin, anim, dur, ease="ease-in-out", extra=""):
    return f"{sel}{{transform-origin:{origin};animation:{anim} {dur}s {ease} infinite{extra}}}"


# ---- A · Trot: the whole yak walks in place ----------------------------------------------------------------------------
def option_a():
    p, T = "ya", 0.8
    css = (
        f"@keyframes {p}-la{{0%,100%{{transform:rotate(24deg)}}50%{{transform:rotate(-24deg)}}}}"
        f"@keyframes {p}-lb{{0%,100%{{transform:rotate(-24deg)}}50%{{transform:rotate(24deg)}}}}"
        f"@keyframes {p}-bob{{0%,50%,100%{{transform:translateY(0) rotate(0)}}25%{{transform:translateY(-5px) rotate(1.2deg)}}75%{{transform:translateY(-5px) rotate(-1.2deg)}}}}"
        f"@keyframes {p}-nod{{0%,50%,100%{{transform:rotate(2deg)}}25%,75%{{transform:rotate(-7deg)}}}}"
        f"@keyframes {p}-tail{{0%,100%{{transform:rotate(16deg)}}50%{{transform:rotate(-12deg)}}}}"
        f"@keyframes {p}-c1{{0%,50%,100%{{transform:translate(0,0) rotate(0)}}25%{{transform:translate(1px,-2px) rotate(1deg)}}75%{{transform:translate(-1px,-2px) rotate(-1deg)}}}}"
        f"@keyframes {p}-c3{{0%,50%,100%{{transform:translate(0,0) rotate(0)}}25%{{transform:translate(3px,-4px) rotate(2.5deg)}}75%{{transform:translate(-3px,-4px) rotate(-2.5deg)}}}}"
        + rule(f".{p}-la", "50% 8%", f"{p}-la", T) + rule(f".{p}-lb", "50% 8%", f"{p}-lb", T)
        + rule(f".{p}-body", "40% 100%", f"{p}-bob", T) + rule(f".{p}-head", "10% 60%", f"{p}-nod", T)
        + rule(f".{p}-tail", "100% 80%", f"{p}-tail", T)
        + rule(f".{p}-c1", "50% 100%", f"{p}-c1", T) + rule(f".{p}-c3", "50% 100%", f"{p}-c3", T, extra=";animation-delay:-.05s")
        + reduced(p))
    body = (f'<g class="{p}-body">{legs(p)}<g class="{p}-tail">{TAIL}</g><path d="{BODY}"/>'
            f'<g class="{p}-head">{head()}</g>'
            f'<g fill="var(--accent)">{card(0, p + "-c1")}{card(1, p + "-c1")}{card(2, p + "-c3")}</g></g>')
    return svg(p, "24 -8 278 224", css, body, "loading"), T


# ---- B · Haul: cards land on its back one by one, then it ships them forward --------------------------------------
def option_b():
    p, T = "yb", 1.6
    far, gone = "translate(-70px,-40px) rotate(-16deg)", "translate(60px,-50px) rotate(18deg)"  # leave up-right, clear of the body
    at = ";animation-delay:-.96s"  # a mount starts at 60 %: the full stack (the brand mark) shows first
    land = [(4, 18), (24, 38), (44, 58)]        # % windows: card k slides in from behind the tail

    def c(k, a, b):
        return (f"@keyframes {p}-c{k}{{0%,{a}%{{opacity:0;transform:{far}}}{b}%,74%{{opacity:1;transform:none}}"
                f"{78 + k}%{{opacity:1;transform:translate(14px,-6px) rotate(-5deg)}}{90 + k}%,100%{{opacity:0;transform:{gone}}}}}")
    css = ("".join(c(k, a, b) for k, (a, b) in enumerate(land, 1))
           + f"@keyframes {p}-sq{{0%,13%,22%,33%,42%,53%,62%,72%,100%{{transform:scale(1,1)}}18%,38%,58%{{transform:scale(1.02,.96)}}"
             f"80%{{transform:translateY(-6px) scale(.98,1.03)}}88%{{transform:translateY(0) scale(1,1)}}}}"
           + f"@keyframes {p}-nod{{0%,12%,24%,32%,44%,52%,66%,100%{{transform:rotate(0)}}18%,38%,58%{{transform:rotate(9deg)}}"
             f"76%{{transform:rotate(-16deg)}}84%{{transform:rotate(14deg)}}92%{{transform:rotate(-3deg)}}}}"
           + f"@keyframes {p}-tail{{0%,100%{{transform:rotate(0)}}18%,58%{{transform:rotate(20deg)}}38%{{transform:rotate(-10deg)}}80%{{transform:rotate(-14deg)}}}}"
           + "".join(rule(f".{p}-c{k}", "50% 100%", f"{p}-c{k}", T, "ease-out", at) for k in (1, 2, 3))
           + rule(f".{p}-body", "50% 100%", f"{p}-sq", T, extra=at) + rule(f".{p}-head", "10% 60%", f"{p}-nod", T, extra=at)
           + rule(f".{p}-tail", "100% 80%", f"{p}-tail", T, extra=at) + reduced(p))
    body = (f'{legs(p)}<g class="{p}-body"><g class="{p}-tail">{TAIL}</g><path d="{BODY}"/>'
            f'<g class="{p}-head">{head()}</g>'
            f'<g fill="var(--accent)">{card(0, p + "-c1")}{card(1, p + "-c2")}{card(2, p + "-c3")}</g></g>')
    return svg(p, "24 -8 278 224", css, body, "loading"), T



LOADERS = {"a": option_a, "b": option_b}


def ts_string(s):
    """A TS string literal as Prettier prints it: the quote that needs fewer escapes, double on a tie."""
    if s.count('"') > s.count("'"):
        return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"
    return json.dumps(s)


def main():
    ts = ["// Generated by scripts/logo/loader.py — do not edit by hand.",
          "export const YAK_LOADERS: Record<\"a\" | \"b\", string> = {"]
    for key, make in LOADERS.items():
        svg_src, _ = make()
        ts.append(f"  {key}: {ts_string(svg_src)},")
        for skin, (ink, accent) in SKINS.items():
            out = (svg_src.replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ', 1)
                   .replace("currentColor", ink).replace("var(--accent)", accent))
            with open(os.path.join(ROOT, "public", "static", f"yak-loader-{key}-{skin}.svg"), "w") as f:
                f.write(out + "\n")
            # reduced motion: a CSS background SVG ignores the page's media queries → a still copy (no <style>)
            with open(os.path.join(ROOT, "public", "static", f"yak-loader-{key}-{skin}-still.svg"), "w") as f:
                f.write(re.sub(r"<style>.*?</style>", "", out) + "\n")
    ts.append("};")
    with open(os.path.join(ROOT, "frontend", "src", "components", "yakLoaders.ts"), "w") as f:
        f.write("\n".join(ts) + "\n")


if __name__ == "__main__":
    main()

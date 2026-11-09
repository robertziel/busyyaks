#!/usr/bin/env python3
"""busyyaks logo generator: a yak at work, still and animated, Light and Dark.

    docker run --rm -v "$PWD":/app -w /app python:3.13-slim python scripts/logo/build.py

writes public/static/logo-{light,dark}.svg (still), logo-{light,dark}-animated.svg (the header's: one short work
burst every CYCLE seconds, pure CSS inside the SVG, so it runs in an <img>; prefers-reduced-motion → still) and
icon.svg (still). The wordmark outlines are scripts/logo/wordmark-{ink,accent}.d. Pass --out DIR --load bars|cards
to write an experiment somewhere else.
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SKINS = {"light": ("#16181D", "#C2410C"), "dark": ("#ECEEF2", "#FF8A3D")}
ICON_BG = "#0F1115"
CYCLE = 60.0   # seconds between work bursts in the header
START = 0.6    # the first burst, after load
STEP = 0.3     # one stride (seconds)


def wordmark(part):
    with open(os.path.join(HERE, f"wordmark-{part}.d")) as f:
        return f.read().strip()


# ---- the yak, in its own coordinates (x 28..296, y 0..212) ----------------------------------------------------------

LEGS = [(78, "a"), (112, "b"), (180, "b"), (212, "a")]  # diagonal pairs swing together
BODY = ("M58 146 C50 128 58 110 74 104 C76 92 92 86 104 90 C110 80 126 78 136 84 C146 76 162 76 170 84 C180 78 196 80 "
        "202 90 C212 88 222 96 222 106 C232 118 230 136 226 150 Q232 168 228 180 Q220 170 212 172 Q210 186 200 190 "
        "Q194 176 186 176 Q180 190 170 192 Q166 178 156 178 Q150 192 140 192 Q136 178 126 178 Q118 190 108 188 "
        "Q106 176 96 174 Q88 186 78 182 Q80 170 72 166 Q62 172 56 166 Q60 156 58 146 Z")
HEAD = [
    "M220 100 C204 92 198 72 206 58 C209 54 214 56 214 61 C214 74 222 84 236 90 Z",            # horn
    "M266 86 C280 78 284 64 278 52 C280 47 287 49 288 54 C294 70 290 88 276 96 Z",             # horn
    "M216 120 C200 112 186 116 182 126 C192 132 206 132 218 128 Z",                            # ear
    "M212 104 C210 88 228 78 244 82 C258 76 276 82 282 96 C294 104 296 122 290 136 C292 150 284 164 270 168 "
    "C256 176 236 172 226 160 C212 156 204 140 208 126 C202 118 204 108 212 104 Z",            # head
    "M230 162 Q232 182 242 178 Q248 192 256 178 Q266 186 268 168 Z",                           # beard
]
# the load on its back: three task cards (x, y, w, h, tilt) or the old three bars
CARDS = [(98, 58, 100, 26, -2), (106, 31, 90, 24, 3), (116, 6, 76, 22, -4)]
BARS = [(106, 20, 22, 52), (138, 38, 22, 34), (170, 20, 22, 52)]


def yak(ink, accent, load, uid, animated=False):
    eye = f"{uid}-eye"
    lines = f"{uid}-lines"
    out = [f'<mask id="{eye}"><rect x="150" y="0" width="200" height="220" fill="#fff"/>'
           f'<circle cx="266" cy="124" r="6" fill="#000"/></mask>']
    if load == "cards":
        # each card carries two "text" lines, cut out so the background shows through
        cut = "".join(f'<g transform="rotate({t} {x + w / 2} {y + h / 2})">'
                      f'<rect x="{x + 9}" y="{y + 7}" width="{w * .55:.0f}" height="4.5" rx="2.25"/>'
                      f'<rect x="{x + 9}" y="{y + h - 11.5}" width="{w * .32:.0f}" height="4.5" rx="2.25"/></g>'
                      for x, y, w, h, t in CARDS)
        out.append(f'<mask id="{lines}"><rect x="0" y="-20" width="320" height="140" fill="#fff"/>'
                   f'<g fill="#000">{cut}</g></mask>')
    if animated:
        out.append(f'<g class="dust" fill="{ink}"><circle class="d1" cx="70" cy="206" r="7"/>'
                   f'<circle class="d2" cx="58" cy="200" r="5"/><circle class="d3" cx="202" cy="208" r="6"/>'
                   f'<circle class="d4" cx="312" cy="204" r="8"/><circle class="d5" cx="340" cy="200" r="6"/></g>')
        # the backlog heap (animated logo only): outlined tiles = work not done yet; the cards on its back are done
        out.append(f'<g class="pile" fill="none" stroke="{accent}" stroke-width="6">' + "".join(
            f'<g class="pile-{k + 1}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" transform="rotate({t} {x + w / 2} {y + h / 2})"/>'
            f'<path d="M{x + 8} {y + h / 2}h{w * .5:.0f}" stroke-width="4.5" stroke-linecap="round" '
            f'transform="rotate({t} {x + w / 2} {y + h / 2})"/></g>' for k, (x, y, w, h, t) in enumerate(PILE)) + "</g>")
    out.append(f'<g class="yak" fill="{ink}">')
    out.append(f'<g class="tail"><path d="M62 136 C46 130 40 116 44 102" fill="none" stroke="{ink}" stroke-width="8" '
               f'stroke-linecap="round"/><path d="M44 104 C32 100 32 84 42 80 C44 70 58 70 58 80 C66 84 64 98 54 102 '
               f'C52 108 46 108 44 104 Z"/></g>')
    for i, (x, pair) in enumerate(LEGS):
        out.append(f'<rect class="leg leg-{pair}" x="{x}" y="150" width="26" height="62" rx="9"/>')
    out.append(f'<path d="{BODY}"/>')
    out.append(f'<g class="head"><g mask="url(#{eye})">' + "".join(f'<path d="{d}"/>' for d in HEAD) + "</g></g>")
    if load == "cards":
        out.append(f'<g fill="{accent}">')
        for i, (x, y, w, h, t) in enumerate(CARDS):
            out.append(f'<g class="load load-{i + 1}" mask="url(#{lines})"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" '
                       f'transform="rotate({t} {x + w / 2} {y + h / 2})"/></g>')
        out.append("</g>")
    else:
        out.append(f'<g fill="{accent}">' + "".join(
            f'<rect class="load load-{i + 1}" x="{x}" y="{y}" width="{w}" height="{h}" rx="6"/>'
            for i, (x, y, w, h) in enumerate(BARS)) + "</g>")
    out.append("</g>")
    return "".join(out)


# ---- the work burst: a backlog heap pops up in front of the yak, it lowers its head and plows it away ----------------

PILE = [(321, 167, 38, 22, -4), (361, 168, 38, 22, 5),                          # yak coords: on the ground, under
        (300, 190, 38, 22, 0), (341, 190, 38, 22, -2), (382, 190, 38, 22, 3)]  # the wordmark's "bu"
HITS = [1.35, 1.8, 2.3, 2.75, 3.2]  # seconds into the burst each pile tile is shoved off (top row first)
WALK = (0.55, 4.05)        # strides run between these
BURST = 4.9                # back at rest


def keyframes(name, frames, cycle, rest=None):
    """frames: [(seconds from START, declarations)]; rest = the declarations outside the burst."""
    pct = lambda s: f"{(START + s) / cycle * 100:.4f}%"
    rest = frames[0][1] if rest is None else rest
    body = [f"0%{{{rest}}}"] + [f"{pct(s)}{{{v}}}" for s, v in frames] + [f"100%{{{rest}}}"]
    return f"@keyframes {name}{{{''.join(body)}}}"


def env(t):
    """0 → 1 → 0: how hard it works at t (eases into the walk and out of it)."""
    a, b = WALK
    if t <= a or t >= b:
        return 0.0
    up, down = (t - a) / 0.6, (b - t) / 0.6
    x = max(0.0, min(1.0, up, down))
    return x * x * (3 - 2 * x)


def strides():
    a, b = WALK
    n = round((b - a) / STEP)
    return [a + STEP * (i + .5) for i in range(n)]


def tf(v):
    return f"transform:{v}"


def burst(load, cycle):
    mids = strides()
    a, b = WALK
    hit = lambda t: max((max(0.0, 1 - abs(t - h) / .18) for h in HITS), default=0)
    swing = lambda sign: [(0, tf("rotate(0deg)")), (a, tf("rotate(0deg)"))] + [
        (t, tf(f"rotate({sign * (1 if i % 2 == 0 else -1) * 16 * env(t):.1f}deg)")) for i, t in enumerate(mids)] + [
        (b, tf("rotate(0deg)"))]
    # the body leans in while it plows: forward, down, a shove at every hit
    move = [(0, tf("translate(0,0) rotate(0deg)")), (0.3, tf("translate(-3px,0) rotate(-1deg)"))]
    for i, t in enumerate(mids):
        e = env(t)
        move += [(t - STEP / 2, tf(f"translate({6 * e:.1f}px,0) rotate({3 * e:.1f}deg)")),
                 (t, tf(f"translate({6 * e + 6 * hit(t):.1f}px,{-3 * e:.1f}px) rotate({3 * e + 2 * hit(t):.1f}deg)"))]
    move += [(b, tf("translate(0,0) rotate(0deg)")), (BURST, tf("translate(0,0) rotate(0deg)"))]
    # the head: looks up at the heap, drops to plow, nods with the strides, butts at every hit, lifts when it's clear
    head = [(0, tf("rotate(0deg)")), (0.25, tf("rotate(-8deg)")), (0.5, tf("rotate(-8deg)")), (0.95, tf("rotate(26deg)"))]
    head += [(t, tf(f"rotate({26 + (3 if i % 2 == 0 else -2) + 8 * hit(t):.1f}deg)")) for i, t in enumerate(mids) if t > 1]
    head += [(b, tf("rotate(22deg)")), (b + .4, tf("rotate(-10deg)")), (b + .65, tf("rotate(-6deg)")), (BURST, tf("rotate(0deg)"))]
    tail = [(0, tf("rotate(0deg)")), (0.2, tf("rotate(24deg)")), (0.4, tf("rotate(-6deg)"))] + [
        (t, tf(f"rotate({(20 if i % 2 == 0 else -14) * env(t):.1f}deg)")) for i, t in enumerate(mids)] + [
        (b + .3, tf("rotate(22deg)")), (b + .55, tf("rotate(-8deg)")), (BURST, tf("rotate(0deg)"))]
    css = [keyframes("leg-a", swing(1), cycle), keyframes("leg-b", swing(-1), cycle), keyframes("move", move, cycle),
           keyframes("head", head, cycle), keyframes("tail", tail, cycle)]
    if load == "cards":
        sway = lambda amp, lag: [(0, tf("translate(0,0) rotate(0deg)"))] + [
            (t + lag, tf(f"translate({amp * env(t) * (1 if i % 2 == 0 else -1):.1f}px,{-amp * env(t):.1f}px) "
                         f"rotate({amp * env(t) * (1 if i % 2 == 0 else -1) / 2:.1f}deg)")) for i, t in enumerate(mids)] + [
            (b + lag + .3, tf("translate(0,0) rotate(0deg)"))]
        # the top card slides back at the hardest shove and is nodded on again when the head lifts
        top = [(0, tf("translate(0,0) rotate(0deg)")), (HITS[1], tf("translate(-4px,-4px) rotate(-4deg)")),
               (HITS[1] + .3, tf("translate(-16px,-6px) rotate(-12deg)")), (b, tf("translate(-14px,-8px) rotate(-10deg)")),
               (b + .4, tf("translate(3px,-10px) rotate(4deg)")), (b + .7, tf("translate(0,0) rotate(0deg)"))]
        css += [keyframes("load-1", sway(1.5, .04), cycle), keyframes("load-2", sway(3, .08), cycle),
                keyframes("load-3", top, cycle)]
    else:
        meter = lambda phase: [(0, tf("scaleY(1)"))] + [
            (t, tf(f"scaleY({1 + ([-.55, .15, -.3, .25][(i + phase) % 4]) * env(t):.2f})")) for i, t in enumerate(mids)] + [
            (b, tf("scaleY(1)"))]
        css += [keyframes(f"load-{n}", meter(n), cycle) for n in (1, 2, 3)]
    # the heap: pops up (overshoot), waits, is shoved forward tumbling and gone
    hidden = "opacity:0;transform:translate(0,8px) scale(0) rotate(0deg)"
    for k, h in enumerate(HITS):
        pop = .06 + .07 * k
        spin = 1 if k % 2 == 0 else -1
        lift = 18 if k < 2 else 8   # the top row is flicked up, the bottom row skids
        frames = [(0, hidden), (pop, hidden), (pop + .18, "opacity:1;transform:translate(0,-7px) scale(1.2) rotate(0deg)"),
                  (pop + .32, "opacity:1;transform:translate(0,0) scale(.92) rotate(0deg)"),
                  (pop + .44, "opacity:1;transform:translate(0,0) scale(1) rotate(0deg)"),
                  (h - .1, "opacity:1;transform:translate(0,0) scale(1) rotate(0deg)"),
                  (h + .04, "opacity:1;transform:translate(-2px,1px) scale(1.08,.88) rotate(0deg)"),
                  (h + .28, f"opacity:1;transform:translate(36px,{-lift}px) scale(1) rotate({spin * 50}deg)"),
                  (h + .62, f"opacity:0;transform:translate(84px,{-lift / 3:.0f}px) scale(.6) rotate({spin * 140}deg)")]
        css.append(keyframes(f"pile-{k + 1}", frames, cycle, rest=hidden))
    # dust: under the hooves while it walks, and a burst out of the heap at every hit
    def puff(at, dx, dy):
        out = []
        for t in at:
            out += [(t, "opacity:0;transform:translate(0,0) scale(.2)"), (t + .05, "opacity:.5;transform:translate(0,0) scale(.5)"),
                    (t + .55, f"opacity:0;transform:translate({dx}px,{dy}px) scale(1.5)")]
        return out
    feet = [t for i, t in enumerate(mids) if i % 2 == 0 and env(t) > .3]
    for n, frames in (("d1", puff(feet, -24, -10)), ("d2", puff([t + .1 for t in feet], -18, -14)),
                      ("d3", puff(feet[1::2], -14, -8)), ("d4", puff(HITS, 20, -16)), ("d5", puff([h + .05 for h in HITS], 8, -26))):
        css.append(keyframes(n, frames, cycle, rest="opacity:0"))
    run = lambda name, origin, anim=None: (f".{name}{{transform-box:fill-box;transform-origin:{origin};"
                                           f"animation:{anim or name} {cycle:g}s ease-in-out infinite}}")
    rules = [run("leg-a", "50% 8%"), run("leg-b", "50% 8%"), run("yak", "30% 100%", "move"),
             run("head", "10% 60%"), run("tail", "100% 80%")]
    rules += [run(f"load-{n}", "30% 100%" if (load == "cards" and n == 3) else "50% 100%") for n in (1, 2, 3)]
    rules += [run(f"pile-{k + 1}", "50% 100%") for k in range(len(PILE))]
    rules += [f".{n}{{opacity:0;transform-box:fill-box;transform-origin:50% 50%;animation:{n} {cycle:g}s ease-out infinite}}"
              for n in ("d1", "d2", "d3", "d4", "d5")]
    return ("<style>" + "".join(css) + "".join(rules) +
            "@media (prefers-reduced-motion:reduce){*{animation:none!important}.dust,.pile{display:none}}</style>")


def logo(skin, load, animated, cycle):
    ink, accent = SKINS[skin]
    uid = f"by-{skin}"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="791" height="230" viewBox="0 -10 790.7 230.5" role="img" '
            f'aria-label="busyyaks">{burst(load, cycle) if animated else ''}'
            f'<g transform="translate(24 24) scale(0.8455882352941176) translate(-28 -12)">{yak(ink, accent, load, uid, animated)}</g>'
            f'<path fill="{ink}" d="{wordmark("ink")}"/><path fill="{accent}" d="{wordmark("accent")}"/></svg>\n')


def icon(load):
    ink, accent = SKINS["dark"]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240">'
            f'<rect width="240" height="240" rx="48" fill="{ICON_BG}"/>'
            f'<g transform="translate(120 128) scale(.74) translate(-162 -110)">{yak(ink, accent, load, "by-icon")}</g></svg>\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..", "public", "static"))
    ap.add_argument("--load", choices=["cards", "bars"], default="cards")
    ap.add_argument("--cycle", type=float, default=CYCLE)
    a = ap.parse_args()
    files = {f"logo-{s}.svg": logo(s, a.load, False, a.cycle) for s in SKINS}
    files.update({f"logo-{s}-animated.svg": logo(s, a.load, True, a.cycle) for s in SKINS})
    files["icon.svg"] = icon(a.load)
    for name, svg in files.items():
        with open(os.path.join(a.out, name), "w") as f:
            f.write(svg)
        print(f"{name}  {len(svg)} B")


if __name__ == "__main__":
    main()

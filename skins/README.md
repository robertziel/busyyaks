# Skins

Every skin of the dashboard is one file here: `<key>.yml`. The settings cog's Skin switch lists them —
Light · Dark · Auto (the system's light or dark) · then every other file by key. A new skin is a new file
(by hand or by an agent); restart the services to load it. A bad file stops the boot and names the reason.

```yaml
label: Ocean          # shown in the cog, 1-40 characters
base: dark            # light | dark: the skin starts from that base skin's colours and its rules
tokens:               # any of the colour tokens (Busyyaks::Skins::TOKENS), over the base's
  "--bg": "#0b2a3a"
  "--accent": "#36d1c4"
```

- `light.yml` and `dark.yml` are the two bases: each sets every token. Light is the default.
- Values: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)` or `rgba(r, g, b, a)`. `--ok`, `--warn`, `--bad`,
  `--accent` take hex only (their `-rgb` triple for tints is derived).
- The key (file name): `a-z`, `0-9`, `-`, starting with a letter; never `auto`.

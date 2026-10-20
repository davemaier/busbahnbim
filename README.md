# BusBahnBim for Omarchy

An Omarchy shell bar widget for public transport in Styria (Verbundlinie / BusBahnBim).

- **Bar:** shows the next departure from your stop, e.g. `󰔬 7 Wetzelsdorf 3′ +1`. A red `+N` means N minutes of delay.
- **Popup, Abfahrten tab:** the full live departure board. You can switch to another stop here.
- **Popup, Verbindung tab:** connection search from A to B, with legs, transfers and live delays.

Data comes from the HAFAS API behind <https://verkehrsauskunft.verbundlinie.at/>. The API is undocumented and has no key; the plugin sends the same public client values as the website.

## Install

```bash
ln -s ~/coding/busbahnbim ~/.config/omarchy/plugins/david.busbahnbim
omarchy-shell shell rescanPlugins
omarchy plugin enable david.busbahnbim
```

To move the widget: `omarchy bar move david.busbahnbim --section center`

## Use

| Action | Effect |
|---|---|
| Left click | open / close popup |
| Middle click | refresh |
| `s` / Enter (Abfahrten) | change stop |
| `d` / `v` | switch tab |
| `r` | refresh |
| Up/Down, Enter, Esc | pick a stop suggestion |

The time field takes `jetzt` (the default) or a time like `7:45`.

IPC: `omarchy-shell david.busbahnbim toggle|refresh|search`.
For example, to bind connection search to a key, run `omarchy-shell david.busbahnbim search`.

## Settings

These go on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `stationId` / `stationName` | `460428100` / Graz Uni/Beethovenstraße | default stop |
| `lines` | `""` | lines shown in the bar, e.g. `"1, 7"` |
| `direction` | `""` | bar only shows destinations containing this text |
| `showDirection` | `true` | show the destination in the bar |
| `refreshIntervalSec` | `60` | how often departures are fetched |

A stop picked in the popup is saved in `~/.local/state/busbahnbim.json` and takes priority over `stationId`. To go back to the default, delete that file and run `omarchy restart shell`.

## Files

- `Panel.qml`: the bar pill and the popup
- `StopSearch.qml`: stop input with live suggestions
- `LineBadge.qml`: line badge (icon + number)
- `Hafas.js`: API client and parsing

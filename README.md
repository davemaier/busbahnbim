# BusBahnBim for Omarchy

> **Note:** This plugin is entirely AI-generated and was built for one specific use case: my own commute in Graz. It has had very little polish. Use it as it is, or as a starting point.

An Omarchy shell bar widget for public transport in Styria (Verbundlinie / BusBahnBim).

- **Bar:** shows the next departure from your stop with its actual (live) departure time, e.g. `󰔬 7 12:07`.
- **Favorites:** star a stop in the popup header to make it a favorite. Favorites appear as chips at the top of the popup; click one (or press 1–9) to switch to it. Right-click the bar to cycle through them.
- **Popup, Departures tab:** the full live departure board. You can switch to another stop here, and click line chips to pick which lines the bar shows for that stop.
- **Popup, Connections tab:** connection search from A to B, with legs, transfers and live delays.

Data comes from the HAFAS API behind <https://verkehrsauskunft.verbundlinie.at/>. The API is undocumented and has no key; the plugin sends the same public client values as the website.

## Install

```bash
ln -s ~/coding/busbahnbim ~/.config/omarchy/plugins/david.busbahnbim
omarchy-shell shell rescanPlugins
omarchy plugin enable david.busbahnbim
```

The shell doesn't notice file changes through the symlink, so after editing, run `omarchy restart shell`.

To move the widget: `omarchy bar move david.busbahnbim --section center`

## Use

| Action | Effect |
|---|---|
| Left click | open / close popup |
| Middle click | refresh |
| Right click | next favorite stop |
| `s` / Enter (Departures) | change stop |
| `f` | add / remove current stop as favorite |
| `1`–`9` | switch to favorite |
| `d` / `c` | switch tab |
| `r` | refresh |
| Up/Down, Enter, Esc | pick a stop suggestion |

The time field takes `now` (the default) or a time like `7:45`.

IPC: `omarchy-shell david.busbahnbim toggle|refresh|search|toggleLine <line>|toggleFavorite|nextFavorite`.
For example, to bind connection search to a key, run `omarchy-shell david.busbahnbim search`.

## Settings

These go on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `stationId` / `stationName` | `460428100` / Graz Uni/Beethovenstraße | default stop |
| `lines` | `""` | lines shown in the bar, e.g. `"1, 7"`; used only for stops with no lines picked in the popup |
| `direction` | `""` | bar only shows destinations containing this text |
| `showDirection` | `false` | show the destination in the bar |
| `refreshIntervalSec` | `60` | how often departures are fetched |

The stop, the favorites and the per-stop lines picked in the popup are saved in `~/.local/state/busbahnbim.json`. The saved stop takes priority over `stationId`. To go back to the default, delete that file and run `omarchy restart shell`.

## Refresh

- Departures are fetched every `refreshIntervalSec` (60 s by default). The rate goes up to every 20 s while the popup is open or the next bus leaves within 5 minutes.
- Opening the popup, switching stops and waking from sleep each trigger an immediate fetch.
- Each request runs as its own `curl` process with an 8 s limit, so a dead connection (e.g. after sleep) can't block refreshing. A failed request is retried after 5 s, then 15 s, then 45 s, up to the normal interval. The last good data stays on screen, and the bar dims once it is more than 3 minutes old.
- Connection results re-run every minute while the Connections tab is open. This stops once you load later connections.

## Files

- `Panel.qml`: the bar pill and the popup
- `StopSearch.qml`: stop input with live suggestions
- `LineBadge.qml`: line badge (icon + number)
- `Hafas.js`: API requests and parsing
- `Request.qml`: runs one API request with curl

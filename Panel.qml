import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Hafas.js" as Hafas

// BusBahnBim bar widget: the next departure from one stop in the bar, and a
// popup with the full departure board plus an A -> B connection search.
Panel {
  id: root
  moduleName: "david.busbahnbim"
  ipcTarget: "david.busbahnbim"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // ---- Stop selection --------------------------------------------------
  // The popup's choices are kept in a small state file: the chosen stop wins
  // over the default from the shell.json settings, and `barLines` maps a
  // stop id to the lines the bar should show for that stop.
  property var stationOverride: null
  property var barLines: ({})
  // Favourite stops ({ extId, name }), switchable from the popup and by right click.
  property var favorites: []
  readonly property var station: stationOverride || {
    extId: String(setting("stationId", "460428100")),
    name: String(setting("stationName", "Graz Uni/Beethovenstraße"))
  }
  onStationChanged: { root.departures = []; root.refresh() }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/busbahnbim.json"
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (s && s.extId) root.stationOverride = { extId: String(s.extId), name: String(s.name || s.extId) }
        if (s && s.barLines) root.barLines = s.barLines
        if (s && s.favorites) root.favorites = s.favorites
      } catch (e) {}
    }
  }

  function chooseStation(stop) {
    root.editingStation = false
    keyCatcher.forceActiveFocus()
    if (!stop.extId) return
    root.stationOverride = { extId: stop.extId, name: stop.name }
    root.saveState()
  }

  function saveState() {
    var state = { barLines: root.barLines, favorites: root.favorites }
    if (root.stationOverride) { state.extId = root.stationOverride.extId; state.name = root.stationOverride.name }
    stateFile.setText(JSON.stringify(state))
  }

  readonly property bool isFavorite: favorites.some(function(f) { return f.extId === station.extId })

  function toggleFavorite() {
    var id = root.station.extId
    root.favorites = root.isFavorite
      ? root.favorites.filter(function(f) { return f.extId !== id })
      : root.favorites.concat([{ extId: id, name: root.station.name }])
    root.saveState()
  }

  function selectFavorite(index) {
    var fav = root.favorites[index]
    if (fav) root.chooseStation(fav)
  }

  // Next favourite after the current stop (or the first one).
  function nextFavorite() {
    if (!root.favorites.length) return
    var id = root.station.extId
    var i = root.favorites.findIndex(function(f) { return f.extId === id })
    root.selectFavorite((i + 1) % root.favorites.length)
  }

  // "Graz Jakominiplatz" -> "Jakominiplatz" when the city matches the current stop's.
  function shortStopName(name) {
    var prefix = root.homeCity + " "
    return name.indexOf(prefix) === 0 && name.length > prefix.length ? name.slice(prefix.length) : name
  }

  // Lines picked in the popup for this stop; empty means the `lines` setting applies.
  readonly property var selectedLines: barLines[station.extId] || []

  function toggleLine(line) {
    var lines = root.selectedLines.slice()
    var i = lines.indexOf(line)
    if (i >= 0) lines.splice(i, 1)
    else lines.push(line)
    var all = Object.assign({}, root.barLines)
    if (lines.length) all[root.station.extId] = lines
    else delete all[root.station.extId]
    root.barLines = all
    root.saveState()
  }

  // Every line seen at this stop (plus picked ones not running right now), as chips.
  readonly property var lineChoices: {
    var seen = {}, list = []
    departures.forEach(function(d) {
      if (!seen[d.line]) { seen[d.line] = true; list.push({ line: d.line, kind: d.kind }) }
    })
    selectedLines.forEach(function(l) {
      if (!seen[l]) { seen[l] = true; list.push({ line: l, kind: "other" }) }
    })
    // Numbers first in numeric order (1, 7, 31, 200), then names like N1 or X30.
    return list.sort(function(a, b) {
      var na = parseInt(a.line, 10), nb = parseInt(b.line, 10)
      if (!isNaN(na) && !isNaN(nb) && na !== nb) return na - nb
      if (isNaN(na) !== isNaN(nb)) return isNaN(na) ? 1 : -1
      return a.line < b.line ? -1 : a.line > b.line ? 1 : 0
    })
  }

  // ---- Departures ------------------------------------------------------
  property var departures: []
  property string error: ""
  property bool loading: false
  property double updatedMs: 0
  property double nowMs: Date.now()
  property int requestId: 0

  readonly property var upcoming: departures.filter(function(d) {
    return !d.cancelled && d.time.getTime() > nowMs - 30000
  })
  readonly property var barDepartures: Hafas.filterDepartures(upcoming,
    selectedLines.length ? selectedLines.join(",") : setting("lines", ""), setting("direction", ""))
  readonly property var next: barDepartures.length ? barDepartures[0] : null

  property int failures: 0

  // Data older than three minutes is shown dimmed in the bar.
  readonly property bool stale: updatedMs > 0 && nowMs - updatedMs > 180000

  // Several triggers can fire at once (startup, settings, state file), so
  // refresh() only schedules one fetch a moment later.
  function refresh() { refreshDebounce.restart() }

  Timer {
    id: refreshDebounce
    interval: 150
    onTriggered: root.fetchNow()
  }

  // HTTP for Hafas.js: one curl process per request (see Request.qml), which
  // always finishes within 8 s, so a hung connection can't block refreshing.
  Component {
    id: requestComponent
    Request {}
  }

  function post(url, body, cb) {
    requestComponent.createObject(root, { url: url, body: body, callback: cb })
  }

  // An outdated response (e.g. for the previous stop) is ignored via requestId.
  function fetchNow() {
    var id = ++root.requestId
    root.loading = true
    Hafas.fetchDepartures(root.post, root.station, 60, function(err, list) {
      if (id === root.requestId) root.finishRefresh(err, list)
    })
  }

  function finishRefresh(err, list) {
    root.loading = false
    root.error = err || ""
    root.failures = err ? root.failures + 1 : 0
    if (!err) {
      root.departures = list
      root.updatedMs = Date.now()
    }
    root.nowMs = Date.now()
    refreshTimer.interval = root.nextRefreshMs()
    refreshTimer.restart()
  }

  // How long to wait before the next fetch:
  // - after errors, retry soon (5 s, 15 s, 45 s, ...) up to the normal interval
  // - every 20 s while the popup is open or the next bus leaves within 5 minutes
  // - otherwise the configured interval
  function nextRefreshMs() {
    var normal = Math.max(30, Number(root.setting("refreshIntervalSec", 60))) * 1000
    if (root.failures > 0) return Math.min(normal, 5000 * Math.pow(3, root.failures - 1))
    var soon = root.next && root.next.time.getTime() - Date.now() < 5 * 60000
    if (root.opened || soon) return Math.min(normal, 20000)
    return normal
  }

  Timer {
    id: refreshTimer
    interval: 60000
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  // Recount the minutes between fetches. A big jump in the clock means the
  // machine was asleep, so fetch right away instead of showing old data.
  Timer {
    interval: root.opened ? 1000 : 10000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var slept = now - root.nowMs > 120000
      root.nowMs = now
      if (slept) root.refresh()
    }
  }

  // ---- Popup state -----------------------------------------------------
  property string tab: "dep"
  property bool editingStation: false
  readonly property string homeCity: station.name.split(" ")[0]
  readonly property bool typing: stationSearch.editing || fromSearch.editing || toSearch.editing || timeField.activeFocus

  function open() {
    root.controller.show()
    root.refresh()
  }

  function startEditingStation() {
    root.tab = "dep"
    root.editingStation = true
    stationSearch.setStop(null)
    Qt.callLater(stationSearch.focusField)
  }

  function showTripTab() {
    root.tab = "trip"
    if (!fromSearch.stop) fromSearch.setStop(root.station)
    Qt.callLater(function() { (toSearch.stop ? fromSearch : toSearch).focusField() })
  }

  // ---- Connection search -----------------------------------------------
  property var trips: []
  property string tripError: ""
  property bool tripLoading: false
  property int expandedTrip: -1
  property int tripRequestId: 0

  property var tripQuery: null      // { from, to, time } of the shown results
  property bool tripsPaged: false   // "Later connections" was used
  property double tripsUpdatedMs: 0

  // mode: "new" (Search button), "later" (append later trips) or
  // "refresh" (quietly re-run the shown search for fresh delays).
  function searchTrips(mode) {
    var query = mode === "new"
      ? { from: fromSearch.stop, to: toSearch.stop, time: timeField.text }
      : root.tripQuery
    if (!query || !query.from || !query.to) { root.tripError = "Choose a start and a destination"; return }
    var when = Hafas.parseTime(query.time)
    if (!when) { root.tripError = "Enter the time as HH:MM"; return }
    if (mode === "later" && root.trips.length) when = new Date(root.trips[root.trips.length - 1].dep.getTime() + 60000)

    var id = ++root.tripRequestId
    root.tripLoading = true
    if (mode === "new") {
      root.tripQuery = query
      root.tripsPaged = false
      root.trips = []
      root.expandedTrip = -1
      root.tripError = ""
      keyCatcher.forceActiveFocus()
    }
    Hafas.fetchTrips(root.post, query.from, query.to, when, function(err, list) {
      if (id !== root.tripRequestId) return
      root.tripLoading = false
      // A failed background refresh keeps the old results on screen.
      if (err && mode === "refresh") return
      root.tripError = err || (list.length || mode === "later" ? "" : "No connections found")
      if (err) return
      if (mode === "later") { root.trips = root.trips.concat(list); root.tripsPaged = true }
      else root.trips = list
      root.tripsUpdatedMs = Date.now()
    })
  }


  // Keep the shown connections current while the tab is open (skipped once
  // later pages are loaded, so the list doesn't jump around).
  Timer {
    interval: 60000
    repeat: true
    running: root.opened && root.tab === "trip" && root.tripQuery !== null && !root.tripsPaged
    onTriggered: if (!root.tripLoading) root.searchTrips("refresh")
  }

  function swapStops() {
    var from = fromSearch.stop
    fromSearch.setStop(toSearch.stop)
    toSearch.setStop(from)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.opened ? root.close() : root.open() }
    function refresh(): void { root.refresh() }
    function search(): void { root.open(); root.showTripTab() }
    function toggleLine(line: string): void { root.toggleLine(line) }
    function toggleFavorite(): void { root.toggleFavorite() }
    function nextFavorite(): void { root.nextFavorite() }
  }

  // ---- Bar pill --------------------------------------------------------
  readonly property string pillIcon: Hafas.ICONS[next ? next.kind : "tram"]
  readonly property string pillLine: next && !vertical ? next.line : ""
  readonly property string pillDirection: next && !vertical && setting("showDirection", false)
    ? Hafas.shorten(next.direction, 16) : ""
  // Actual (live) departure time; the delay is already included.
  readonly property string pillTime: next ? Hafas.hhmm(next.time) : (error ? "!" : "…")

  component Pill: Row {
    property color textColor: root.foreground
    spacing: Style.space(5)

    Text {
      textFormat: Text.PlainText
      text: root.pillIcon
      color: parent.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      text: root.pillLine
      color: parent.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      text: root.pillDirection
      color: parent.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      textFormat: Text.PlainText
      text: root.pillTime
      color: parent.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Off-screen copy, only used to size the bar button.
  Pill { id: pillMeasure; visible: false }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.vertical ? Style.bar.iconSlot : pillMeasure.implicitWidth + Style.space(12)
    tooltipText: root.opened ? "" : root.tooltip()
    iconComponent: Component {
      Item {
        Pill {
          anchors.centerIn: parent
          textColor: button.foreground
          opacity: root.stale ? 0.5 : 1
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.nextFavorite()
      else root.opened ? root.close() : root.open()
    }
  }

  function tooltip() {
    var lines = [root.station.name]
    root.barDepartures.slice(0, 4).forEach(function(d) {
      lines.push(d.line + " " + d.direction + "  " + Hafas.hhmm(d.time))
    })
    if (root.error) lines.push(root.error)
    lines.push(root.updatedText())
    return lines.join("\n")
  }

  function updatedText() {
    return root.updatedMs ? "Updated " + Hafas.hhmm(new Date(root.updatedMs)) : "Not loaded yet"
  }

  // ---- Popup -----------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, panel.screenH > 0 ? panel.screenH * 0.8 : Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: root.tab === "dep" ? root.startEditingStation() : root.searchTrips("new")
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.startEditingStation()
        else if (t === "f" || t === "F") root.toggleFavorite()
        else if (t === "d" || t === "D") root.tab = "dep"
        else if (t === "c" || t === "C") root.showTripTab()
        else if (t >= "1" && t <= "9") root.selectFavorite(Number(t) - 1)
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: root.station.name
            meta: root.error ? root.error + " · " + root.updatedText()
              : root.updatedMs ? root.updatedText() : "Loading…"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Hafas.ICONS.tram
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(6)
                PanelActionButton {
                  iconText: root.isFavorite ? "\u{F04CE}" : "\u{F04D2}"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: root.isFavorite ? "Remove from favorites (f)" : "Add to favorites (f)"
                  onClicked: root.toggleFavorite()
                }
                PanelActionButton {
                  iconText: "\u{F0349}"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Change stop (s)"
                  onClicked: root.startEditingStation()
                }
                PanelActionButton {
                  iconText: "\u{F0450}"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Refresh (r)"
                  onClicked: root.refresh()
                }
              }
            }
          }

          // Favourite stops: click (or press 1-9) to switch.
          Flow {
            visible: root.favorites.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.favorites

              delegate: Button {
                required property var modelData
                required property int index
                text: (index < 9 ? (index + 1) + "  " : "") + root.shortStopName(modelData.name)
                selected: modelData.extId === root.station.extId
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.selectFavorite(index)
              }
            }
          }

          ButtonGroup {
            options: [{ value: "dep", label: "Departures" }, { value: "trip", label: "Connections" }]
            value: root.tab
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { v === "trip" ? root.showTripTab() : root.tab = "dep" }
          }

          // ---- Departures tab ----
          Column {
            visible: root.tab === "dep"
            width: parent.width
            spacing: Style.space(4)

            StopSearch {
              id: stationSearch
              post: root.post
              visible: root.editingStation
              width: parent.width
              placeholderText: "Search stop"
              preferPrefix: root.homeCity
              foreground: root.foreground
              fontFamily: root.fontFamily
              onPicked: function(stop) { root.chooseStation(stop) }
              onCancelled: { root.editingStation = false; keyCatcher.forceActiveFocus() }
            }

            Text {
              visible: root.lineChoices.length > 0
              textFormat: Text.PlainText
              text: root.selectedLines.length ? "Shown in the bar:" : "Shown in the bar: all lines (click to pick)"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Flow {
              visible: root.lineChoices.length > 0
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.lineChoices

                delegate: LineBadge {
                  required property var modelData
                  readonly property bool picked: root.selectedLines.indexOf(modelData.line) >= 0
                  line: modelData.line
                  kind: modelData.kind
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  opacity: picked || root.selectedLines.length === 0 ? 1 : 0.45
                  border.width: picked ? Math.max(1, Style.space(1)) : 0
                  border.color: root.foreground

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleLine(modelData.line)
                  }
                }
              }
            }

            PanelSeparator {
              visible: root.lineChoices.length > 0
              foreground: root.foreground
            }

            Text {
              visible: root.upcoming.length === 0
              textFormat: Text.PlainText
              text: root.loading ? "Loading departures…" : (root.error ? "Error: " + root.error : "No departures")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.departures.filter(function(d) { return d.time.getTime() > root.nowMs - 30000 }).slice(0, 14)

              delegate: Item {
                required property var modelData
                width: parent.width
                height: Math.max(badge.implicitHeight, Style.space(24))
                opacity: modelData.cancelled ? 0.5 : 1

                LineBadge {
                  id: badge
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  line: modelData.line
                  kind: modelData.kind
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  anchors.left: badge.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: times.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.direction
                  elide: Text.ElideRight
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.strikeout: modelData.cancelled
                }

                Row {
                  id: times
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: Hafas.hhmm(modelData.planned) + (modelData.delay > 0 ? " +" + modelData.delay : "")
                    color: modelData.delay > 0 ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    width: Style.space(44)
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: modelData.cancelled ? "cancelled" : Hafas.countdown(modelData.time, root.nowMs)
                    color: modelData.cancelled ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // ---- Connection tab ----
          Column {
            visible: root.tab === "trip"
            width: parent.width
            spacing: Style.space(6)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Column {
                width: parent.width - swapButton.width - parent.spacing
                spacing: Style.space(6)

                StopSearch {
                  id: fromSearch
                  post: root.post
                  width: parent.width
                  stationsOnly: false
                  placeholderText: "From"
                  preferPrefix: root.homeCity
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onPicked: toSearch.stop ? root.searchTrips("new") : toSearch.focusField()
                  onCancelled: keyCatcher.forceActiveFocus()
                }

                StopSearch {
                  id: toSearch
                  post: root.post
                  width: parent.width
                  stationsOnly: false
                  placeholderText: "To"
                  preferPrefix: root.homeCity
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onPicked: fromSearch.stop ? root.searchTrips("new") : fromSearch.focusField()
                  onCancelled: keyCatcher.forceActiveFocus()
                }
              }

              PanelActionButton {
                id: swapButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\u{F04E1}"
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Swap start and destination"
                onClicked: root.swapStops()
              }
            }

            Row {
              spacing: Style.space(6)

              TextField {
                id: timeField
                width: Style.space(110)
                placeholderText: "now / HH:MM"
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.searchTrips("new"); event.accepted = true }
                  else if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
                }
              }

              Button {
                text: root.tripLoading ? "Searching…" : "Search"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.searchTrips("new")
              }
            }

            Text {
              visible: root.tripError !== ""
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.tripError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.trips.length > 0
              textFormat: Text.PlainText
              text: "Updated " + Hafas.hhmm(new Date(root.tripsUpdatedMs))
                + (root.tripsPaged ? "" : " · refreshes every minute")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.trips

              delegate: Column {
                id: tripRow
                required property var modelData
                required property int index
                readonly property bool expanded: root.expandedTrip === index

                width: parent.width
                spacing: Style.space(4)

                PanelSeparator { foreground: root.foreground }

                Item {
                  width: parent.width
                  height: summary.implicitHeight + Style.space(6)

                  Column {
                    id: summary
                    width: parent.width
                    spacing: Style.space(4)

                    Item {
                      width: parent.width
                      height: tripTimes.implicitHeight

                      Text {
                        id: tripTimes
                        textFormat: Text.PlainText
                        text: Hafas.hhmm(tripRow.modelData.dep) + " – " + Hafas.hhmm(tripRow.modelData.arr)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        font.bold: true
                      }
                      Text {
                        anchors.left: tripTimes.right
                        anchors.leftMargin: Style.space(8)
                        anchors.baseline: tripTimes.baseline
                        visible: tripRow.modelData.delay > 0
                        textFormat: Text.PlainText
                        text: "+" + tripRow.modelData.delay
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        anchors.right: parent.right
                        anchors.baseline: tripTimes.baseline
                        textFormat: Text.PlainText
                        text: Hafas.duration(tripRow.modelData.minutes) + " · "
                          + (tripRow.modelData.changes === 0 ? "direct" : tripRow.modelData.changes + (tripRow.modelData.changes === 1 ? " change" : " changes"))
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }

                    Flow {
                      width: parent.width
                      spacing: Style.space(4)
                      Repeater {
                        model: tripRow.modelData.rides
                        delegate: LineBadge {
                          required property var modelData
                          line: modelData.line
                          kind: modelData.kind
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                        }
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.expandedTrip = tripRow.expanded ? -1 : tripRow.index
                  }
                }

                // Leg-by-leg details.
                Repeater {
                  model: tripRow.expanded ? tripRow.modelData.sections : []

                  delegate: Row {
                    required property var modelData
                    width: tripRow.width
                    spacing: Style.space(8)

                    LineBadge {
                      id: legBadge
                      line: modelData.line
                      kind: modelData.kind
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }

                    Column {
                      width: parent.width - legBadge.width - parent.spacing
                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: Hafas.hhmm(modelData.dep) + "  " + modelData.from
                          + (modelData.platform ? "  (platform " + modelData.platform.trim() + ")" : "")
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        visible: modelData.direction !== ""
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: "→ " + modelData.direction
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: Hafas.hhmm(modelData.arr) + "  " + modelData.to
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }
                }
              }
            }

            Button {
              visible: root.trips.length > 0
              text: "Later connections"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.searchTrips("later")
            }
          }
        }
      }
    }
  }
}

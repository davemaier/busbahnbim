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
  // The popup's choice is kept in a small state file and wins over the
  // default from the shell.json settings.
  property var stationOverride: null
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
      } catch (e) {}
    }
  }

  function chooseStation(stop) {
    root.editingStation = false
    keyCatcher.forceActiveFocus()
    if (!stop.extId) return
    root.stationOverride = { extId: stop.extId, name: stop.name }
    stateFile.setText(JSON.stringify(root.stationOverride))
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
  readonly property var barDepartures: Hafas.filterDepartures(upcoming, setting("lines", ""), setting("direction", ""))
  readonly property var next: barDepartures.length ? barDepartures[0] : null

  function refresh() {
    var id = ++root.requestId
    root.loading = true
    Hafas.fetchDepartures(root.station, 30, function(err, list) {
      if (id !== root.requestId) return
      root.loading = false
      root.error = err || ""
      if (!err) {
        root.departures = list
        root.updatedMs = Date.now()
      }
      root.nowMs = Date.now()
    })
  }

  Timer {
    interval: Math.max(30, Number(root.setting("refreshIntervalSec", 60))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Recount the minutes between fetches.
  Timer {
    interval: root.opened ? 1000 : 10000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
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

  function searchTrips(later) {
    var from = fromSearch.stop, to = toSearch.stop
    if (!from || !to) { root.tripError = "Start und Ziel wählen"; return }
    var when = Hafas.parseTime(timeField.text)
    if (!when) { root.tripError = "Zeit als HH:MM eingeben"; return }
    if (later && root.trips.length) when = new Date(root.trips[root.trips.length - 1].dep.getTime() + 60000)

    var id = ++root.tripRequestId
    root.tripLoading = true
    root.tripError = ""
    if (!later) { root.trips = []; root.expandedTrip = -1 }
    keyCatcher.forceActiveFocus()
    Hafas.fetchTrips(from, to, when, function(err, list) {
      if (id !== root.tripRequestId) return
      root.tripLoading = false
      root.tripError = err || (list.length || later ? "" : "Keine Verbindungen gefunden")
      root.trips = later ? root.trips.concat(list) : list
    })
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
  }

  // ---- Bar pill --------------------------------------------------------
  readonly property string pillIcon: Hafas.ICONS[next ? next.kind : "tram"]
  readonly property string pillLine: next && !vertical ? next.line : ""
  readonly property string pillDirection: next && !vertical && setting("showDirection", true)
    ? Hafas.shorten(next.direction, 16) : ""
  readonly property string pillTime: next ? Hafas.countdown(next.time, nowMs) : (error ? "!" : "…")
  readonly property string pillDelay: next && next.delay > 0 && !vertical ? "+" + next.delay : ""

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
    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      text: root.pillDelay
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
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
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.opened ? root.close() : root.open()
    }
  }

  function tooltip() {
    if (root.error) return root.station.name + "\n" + root.error
    var lines = [root.station.name]
    root.barDepartures.slice(0, 4).forEach(function(d) {
      lines.push(d.line + " " + d.direction + "  " + Hafas.hhmm(d.time) + (d.delay > 0 ? " (+" + d.delay + ")" : ""))
    })
    return lines.join("\n")
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
      onReturnRequested: root.tab === "dep" ? root.startEditingStation() : root.searchTrips(false)
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.startEditingStation()
        else if (t === "d" || t === "D" || t === "1") root.tab = "dep"
        else if (t === "v" || t === "V" || t === "2") root.showTripTab()
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
            meta: root.error ? root.error
              : root.updatedMs ? "Aktualisiert " + Hafas.hhmm(new Date(root.updatedMs)) : "Lade…"
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
                  iconText: "\u{F0349}"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Haltestelle ändern (s)"
                  onClicked: root.startEditingStation()
                }
                PanelActionButton {
                  iconText: "\u{F0450}"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Aktualisieren (r)"
                  onClicked: root.refresh()
                }
              }
            }
          }

          ButtonGroup {
            options: [{ value: "dep", label: "Abfahrten" }, { value: "trip", label: "Verbindung" }]
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
              visible: root.editingStation
              width: parent.width
              placeholderText: "Haltestelle suchen"
              preferPrefix: root.homeCity
              foreground: root.foreground
              fontFamily: root.fontFamily
              onPicked: function(stop) { root.chooseStation(stop) }
              onCancelled: { root.editingStation = false; keyCatcher.forceActiveFocus() }
            }

            Text {
              visible: root.upcoming.length === 0
              textFormat: Text.PlainText
              text: root.loading ? "Lade Abfahrten…" : (root.error ? "Fehler: " + root.error : "Keine Abfahrten")
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
                    text: modelData.cancelled ? "fällt aus" : Hafas.countdown(modelData.time, root.nowMs)
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
                  width: parent.width
                  stationsOnly: false
                  placeholderText: "Von"
                  preferPrefix: root.homeCity
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onPicked: toSearch.stop ? root.searchTrips(false) : toSearch.focusField()
                  onCancelled: keyCatcher.forceActiveFocus()
                }

                StopSearch {
                  id: toSearch
                  width: parent.width
                  stationsOnly: false
                  placeholderText: "Nach"
                  preferPrefix: root.homeCity
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onPicked: fromSearch.stop ? root.searchTrips(false) : fromSearch.focusField()
                  onCancelled: keyCatcher.forceActiveFocus()
                }
              }

              PanelActionButton {
                id: swapButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\u{F04E1}"
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Start und Ziel tauschen"
                onClicked: root.swapStops()
              }
            }

            Row {
              spacing: Style.space(6)

              TextField {
                id: timeField
                width: Style.space(110)
                placeholderText: "jetzt / HH:MM"
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.searchTrips(false); event.accepted = true }
                  else if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
                }
              }

              Button {
                text: root.tripLoading ? "Suche…" : "Suchen"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.searchTrips(false)
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
                          + (tripRow.modelData.changes === 0 ? "direkt" : tripRow.modelData.changes + "× umst.")
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
                          + (modelData.platform ? "  (Steig " + modelData.platform.trim() + ")" : "")
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
              text: "Spätere Verbindungen"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.searchTrips(true)
            }
          }
        }
      }
    }
  }
}

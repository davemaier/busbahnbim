import QtQuick
import qs.Commons
import qs.Ui
import "Hafas.js" as Hafas

// Text field with live stop suggestions from HAFAS LocMatch.
// Up/Down move through suggestions, Enter picks, Escape cancels.
Column {
  id: root

  property alias text: field.text
  property alias placeholderText: field.placeholderText
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool stationsOnly: true
  // Stops starting with this (e.g. "Graz") are listed first.
  property string preferPrefix: ""
  property var stop: null
  readonly property bool editing: field.activeFocus

  property var suggestions: []
  property int suggestionIndex: 0
  property bool loading: false
  property bool pickWhenLoaded: false
  property bool quiet: false
  property int requestId: 0

  signal picked(var stop)
  signal cancelled()

  spacing: Style.space(2)

  function focusField() {
    field.forceActiveFocus()
    field.selectAll()
  }

  // Show a stop without triggering a new search.
  function setStop(stop) {
    root.stop = stop
    root.quiet = true
    field.text = stop ? stop.name : ""
    root.quiet = false
    root.suggestions = []
  }

  function lookup() {
    var query = field.text.trim()
    if (query.length < 2) { root.suggestions = []; return }
    var id = ++root.requestId
    root.loading = true
    Hafas.searchStops(query, root.stationsOnly, function(err, stops) {
      if (id !== root.requestId) return
      root.loading = false
      if (root.preferPrefix) {
        var prefix = root.preferPrefix + " "
        stops = stops.filter(function(s) { return s.name.indexOf(prefix) === 0 })
          .concat(stops.filter(function(s) { return s.name.indexOf(prefix) !== 0 }))
      }
      root.suggestions = stops
      root.suggestionIndex = 0
      if (root.pickWhenLoaded) {
        root.pickWhenLoaded = false
        if (stops.length) root.pick(stops[0])
      }
    })
  }

  function pick(stop) {
    root.setStop(stop)
    root.picked(stop)
  }

  function commit() {
    if (root.suggestions.length) root.pick(root.suggestions[root.suggestionIndex])
    else if (field.text.trim().length >= 2) { root.pickWhenLoaded = true; debounce.stop(); root.lookup() }
  }

  TextField {
    id: field
    width: parent.width
    foreground: root.foreground
    font.family: root.fontFamily

    onTextChanged: if (!root.quiet && activeFocus) debounce.restart()
    onActiveFocusChanged: if (!activeFocus) root.suggestions = []

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.suggestions = []
        root.cancelled()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        if (root.suggestionIndex < root.suggestions.length - 1) root.suggestionIndex++
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        if (root.suggestionIndex > 0) root.suggestionIndex--
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.commit()
        event.accepted = true
      }
    }
  }

  Timer {
    id: debounce
    interval: 250
    onTriggered: root.lookup()
  }

  Repeater {
    model: root.suggestions

    delegate: Rectangle {
      required property var modelData
      required property int index

      width: root.width
      height: label.implicitHeight + Style.space(8)
      radius: Style.space(4)
      color: index === root.suggestionIndex || mouse.containsMouse
        ? Qt.alpha(root.foreground, 0.1) : "transparent"

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        textFormat: Text.PlainText
        text: modelData.name
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.pick(modelData)
      }
    }
  }
}

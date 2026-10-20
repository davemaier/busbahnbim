import QtQuick
import qs.Commons
import "Hafas.js" as Hafas

// Small pill with the vehicle icon and line number, e.g. "󰔬 7".
Rectangle {
  id: root

  property string line: ""
  property string kind: "other"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  implicitWidth: Math.max(row.implicitWidth + Style.space(10), Style.space(48))
  implicitHeight: row.implicitHeight + Style.space(4)
  radius: Style.space(4)
  color: Qt.alpha(foreground, kind === "walk" ? 0.0 : 0.12)

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: Hafas.ICONS[root.kind] || Hafas.ICONS.other
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      text: root.line
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.yassinesawahi.peripheral-battery"

  // The helper sits next to this file, wherever the plugin is installed.
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("peripheral-battery.py").toString().replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: Math.max(30, Number(root.settings.refreshIntervalSec) || 120)
  readonly property int lowThreshold: Number(root.settings.lowThreshold) || 20

  readonly property var order: ["mouse", "keyboard"]
  readonly property var glyphs: ({
    mouse: String.fromCodePoint(0xF037D),     // nf-md-mouse
    keyboard: String.fromCodePoint(0xF030C),  // nf-md-keyboard
    charging: String.fromCodePoint(0xF140B)   // nf-md-lightning_bolt
  })

  // Latest reading per device id. A device that stops answering (asleep,
  // switched off) comes back from the script with its last good numbers
  // flagged stale, so the bar doesn't blank every time the mouse naps.
  property var devices: ({})
  property int lastRead: 0
  property bool popupOpen: false
  property date nowTick: new Date()

  // Device ids already warned about for the current discharge. Cleared once
  // the device charges or climbs back above the threshold.
  property var warned: ({})

  readonly property var barItems: {
    var items = []
    for (var i = 0; i < root.order.length; i++) {
      var d = root.devices[root.order[i]]
      if (!d || d.level === undefined || d.level === null) continue
      items.push({
        glyph: root.glyphs[d.kind],
        text: d.level + "%",
        charging: d.state === "charging",
        low: root.isLow(d),
        stale: !!d.stale
      })
    }
    return items
  }

  readonly property string tooltipLabel: {
    var lines = []
    for (var i = 0; i < root.order.length; i++) {
      var d = root.devices[root.order[i]]
      if (d) lines.push(d.name + ": " + root.summary(d))
    }
    return lines.length ? lines.join("\n") : "Reading peripherals…"
  }

  readonly property real openPanelIndicatorWidth: root.barItems.length ? content.implicitWidth : 0

  function isLow(d) {
    return d.level !== null && d.level !== undefined && d.level <= root.lowThreshold && d.state !== "charging"
  }

  function capitalize(s) {
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""
  }

  function seenLabel(d) {
    return d.seenAt ? Qt.formatTime(new Date(d.seenAt * 1000), "HH:mm") : ""
  }

  function summary(d) {
    if (d.status === "no-access") return "No access to the receiver (udev rule missing)"
    if (d.status === "absent") return "Receiver not plugged in"
    if (d.status === "error") return "Read failed"
    if (d.level === null || d.level === undefined) {
      if (d.stale || d.status === "asleep") return "Asleep"
      return "Connected · level not reported over 2.4G"
    }
    var s = d.level + "% · " + root.capitalize(d.state)
    if (d.stale) s += " · asleep, last seen " + root.seenLabel(d)
    return s
  }

  function detail(d) {
    var parts = []
    if (d.level !== null && d.level !== undefined) {
      parts.push(d.stale ? "Asleep · last seen " + root.seenLabel(d) : root.capitalize(d.state))
      if (d.voltage) parts.push(d.voltage.toFixed(2) + " V")
      if (d.firmware) parts.push("fw " + d.firmware)
      return parts.join(" · ")
    }
    if (d.id === "keyboard" && d.status === "ok")
      return "Connected · hold Fn+Alt to see the level on the number row"
    return root.summary(d)
  }

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function applyReading(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    var list = data.devices || []
    var next = ({})
    for (var i = 0; i < list.length; i++) next[list[i].id] = list[i]
    root.devices = next
    root.lastRead = data.time || 0
    root.checkLow()
  }

  function checkLow() {
    var warned = Object.assign({}, root.warned)
    for (var i = 0; i < root.order.length; i++) {
      var d = root.devices[root.order[i]]
      if (!d || d.stale || d.level === null || d.level === undefined) continue
      if (!root.isLow(d)) {
        if (d.state === "charging" || d.level > root.lowThreshold + 5) warned[d.id] = false
        continue
      }
      if (warned[d.id]) continue
      warned[d.id] = true
      notifyProc.running = false
      notifyProc.command = ["notify-send", "-a", "Peripheral battery",
        "-u", d.level <= 10 ? "critical" : "normal",
        "-i", "battery-caution",
        d.name + " battery low", d.level + "% left, time to charge it"]
      notifyProc.running = true
    }
    root.warned = warned
  }

  // Contract KeyboardPanel expects on its `owner`: called when a click
  // outside dismisses the popup, so the `open` binding below stays intact.
  function close() {
    root.popupOpen = false
  }

  function toggle() {
    root.nowTick = new Date()
    root.popupOpen = !root.popupOpen
  }

  // `omarchy-shell io.github.yassinesawahi.peripheral-battery toggle` — bindable to a key.
  IpcHandler {
    target: "io.github.yassinesawahi.peripheral-battery"

    function toggle() { root.toggle() }
    function close() { root.close() }
    function refresh() { root.refresh() }
  }

  Process {
    id: readProc
    command: ["python3", root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReading(text)
    }
  }

  Process { id: notifyProc }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps the "updated … ago" line honest between reads.
  Timer {
    interval: 30000
    running: root.popupOpen
    repeat: true
    onTriggered: root.nowTick = new Date()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltipLabel
    fixedWidth: root.vertical ? -1 : content.implicitWidth + button.scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.RightButton || b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(10)

      // Nothing read yet: a bare mouse glyph holds the slot.
      OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barItems.length === 0
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.glyphs.mouse
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.foreground
        opacity: 0.5
      }

      Repeater {
        model: root.barItems

        delegate: Row {
          required property var modelData
          readonly property color tint: modelData.low ? root.bar.urgent : button.foreground

          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          opacity: modelData.stale ? 0.55 : 1

          OpticalGlyph {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.bar.iconCanvas
            height: Style.bar.iconCanvas
            text: modelData.glyph
            fontFamily: button.fontFamily
            fontSize: Style.bar.iconFont
            color: parent.tint
          }

          // A vertical bar has no room for the percentage; it stays in the tooltip.
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.vertical
            textFormat: Text.PlainText
            text: (modelData.charging ? root.glyphs.charging : "") + modelData.text
            color: parent.tint
            font.family: button.fontFamily
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        PanelSectionHeader {
          text: "PERIPHERALS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Repeater {
          model: root.order

          delegate: Column {
            id: card
            required property string modelData
            readonly property var dev: root.devices[modelData] || null
            readonly property bool hasLevel: !!dev && dev.level !== null && dev.level !== undefined
            readonly property color tint: hasLevel && root.isLow(dev) ? root.bar.urgent : root.bar.foreground

            visible: dev !== null
            width: col.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Math.max(cardGlyph.implicitHeight, cardText.implicitHeight, cardPercent.implicitHeight)

              Text {
                id: cardGlyph
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: card.dev ? root.glyphs[card.dev.kind] || "" : ""
                color: card.tint
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title * 1.4
              }

              Column {
                id: cardText
                anchors.left: cardGlyph.right
                anchors.leftMargin: Style.space(10)
                anchors.right: cardPercent.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: card.dev ? card.dev.name : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: card.dev ? root.detail(card.dev) : ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Text {
                id: cardPercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: card.hasLevel
                textFormat: Text.PlainText
                text: card.hasLevel
                  ? (card.dev.state === "charging" ? root.glyphs.charging : "") + card.dev.level + "%"
                  : ""
                color: card.tint
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Rectangle {
              visible: card.hasLevel
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

              Rectangle {
                width: card.hasLevel ? parent.width * Math.max(0, Math.min(100, card.dev.level)) / 100 : 0
                height: parent.height
                radius: parent.radius
                color: card.hasLevel && root.isLow(card.dev) ? root.bar.urgent : Color.accent
                opacity: card.dev && card.dev.stale ? 0.5 : 1
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: {
            if (!root.lastRead) return "Reading…"
            var mins = Math.floor((root.nowTick.getTime() / 1000 - root.lastRead) / 60)
            return (mins < 1 ? "Updated just now" : "Updated " + mins + " min ago") + " · right-click to refresh"
          }
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}

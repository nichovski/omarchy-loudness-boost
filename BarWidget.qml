import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "nichovski.loudness-boost"

  readonly property string script: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") || "") + "/.config")
    + "/omarchy/plugins/nichovski.loudness-boost/boostctl.sh"

  property bool active: false
  property real gainDb: 9
  property real minDb: 0
  property real maxDb: 30
  property bool busy: false
  property bool popupOpen: false
  property string errorText: ""
  property var pendingArgs: []

  function close() {
    popupOpen = false
  }

  function refresh() {
    if (!statusProc.running)
      statusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var line = String(raw || "").trim().split("\n").pop()
      var data = JSON.parse(line)
      root.active = data.active === true
      root.gainDb = Number(data.gainDb)
      root.minDb = Number(data.minDb)
      root.maxDb = Number(data.maxDb)
    } catch (e) {
      // Keep the last known state if the backend cannot be read.
    }
  }

  function runAction(args) {
    if (actionProc.running)
      return
    root.busy = true
    root.errorText = ""
    root.pendingArgs = args
    actionProc.running = true
  }

  function toggle() {
    if (root.active)
      root.runAction(["disable"])
    else
      root.runAction(["enable"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["bash", root.script, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: actionProc
    command: ["bash", root.script].concat(root.pendingArgs)
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "")
          root.errorText = message.split("\n").pop()
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.errorText === "")
        root.errorText = "Boost command failed"
      root.refresh()
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.active ? "\u{f057e}" : "\u{f0581}"
    tooltipText: root.active
      ? "Loudness Boost: +" + Math.round(root.gainDb) + " dB (middle-click to turn off)"
      : "Loudness Boost: off (middle-click to turn on)"
    active: root.active
    activeColor: Color.accent
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton)
        root.toggle()
      else
        root.popupOpen = !root.popupOpen
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "LOUDNESS BOOST"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        width: parent.width
      }

      Toggle {
        width: parent.width
        label: "Make quiet audio louder"
        description: root.active
          ? "On · +" + Math.round(root.gainDb) + " dB into a -1 dB limiter"
          : "Off · audio plays untouched"
        checked: root.active
        foreground: root.bar.foreground
        accent: Color.accent
        fontFamily: root.bar.fontFamily
        onClicked: root.toggle()
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        opacity: root.active ? 1.0 : 0.5

        Item {
          width: parent.width
          implicitHeight: Math.max(gainLabel.implicitHeight, gainValue.implicitHeight)

          Text {
            id: gainLabel
            textFormat: Text.PlainText
            text: "BOOST"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: gainValue
            textFormat: Text.PlainText
            text: "+" + Math.round(gainSlider.dragging ? gainSlider.liveValue : root.gainDb) + " dB"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: gainSlider
          width: parent.width
          bar: root.bar
          minimum: root.minDb
          maximum: root.maxDb
          step: 1
          value: root.gainDb
          enabled: root.active && !root.busy
          onReleased: function(v) { root.runAction(["set", String(Math.round(v))]) }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.bar.foreground
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorText
        color: Color.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Routes the current output through a gain and limiter so quiet sources reach full volume without clipping. Turn it off to return your audio to the normal output."
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
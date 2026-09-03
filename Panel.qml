import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "lukedaduke.fan"
  ipcTarget: "lukedaduke.fan"

  property string currentMode: "high"
  property int cpuLoad: 0
  property int memPct: 0
  property string memUsed: "--"
  property string memAvail: "--"
  property string memTotal: "--"
  property string swapUsed: "--"
  property string swapTotal: "--"
  property int swapPct: 0
  property string cpuTemp: "--"
  property string gpuTemp: "--"
  property string nvmeTemp: "--"
  property int fan1Rpm: 0
  property int fan2Rpm: 0
  property var topMem: []
  property bool isRefreshing: false
  property string fetchError: ""
  property bool fanControl: false
  property int selectedProc: 0

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color surface: Color.popups.background
  readonly property string pluginRoot: {
    var p = Qt.resolvedUrl(".").toString()
    if (p.indexOf("file://") === 0)
      p = p.substring(7)
    if (p.length > 1 && p.charAt(p.length - 1) === "/")
      p = p.substring(0, p.length - 1)
    return p
  }

  function setMode(mode) {
    if (!mode || !root.fanControl)
      return
    currentMode = mode
    Quickshell.execDetached(["omarchy-fan-set", mode])
    refreshTimer.restart()
  }

  function cycleMode() {
    if (!root.fanControl)
      return
    if (currentMode === "low")
      setMode("med")
    else if (currentMode === "med")
      setMode("high")
    else
      setMode("low")
  }

  function killProcess(pid) {
    if (!pid || pid <= 1)
      return
    Quickshell.execDetached(["python3", root.pluginRoot + "/bin/kill_proc.py", pid.toString()])
    refreshTimer.restart()
  }

  function refresh() {
    if (!statusProc.running) {
      root.isRefreshing = true
      statusProc.running = true
    }
  }

  function memColor() {
    if (root.memPct >= 85)
      return root.urgent
    if (root.memPct >= 70)
      return root.accent
    return root.fg
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["python3", root.pluginRoot + "/bin/system_monitor_stats.py"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isRefreshing = false
        try {
          if (!text || text.trim().length === 0) {
            root.fetchError = "empty stats"
            return
          }
          var data = JSON.parse(text)
          if (data.ok === false) {
            root.fetchError = data.error || "stats failed"
            return
          }
          root.fetchError = ""
          if (data.fan_mode)
            root.currentMode = String(data.fan_mode).trim()
          if (data.cpu_load !== undefined)
            root.cpuLoad = Math.max(0, Math.min(100, parseInt(data.cpu_load) || 0))
          if (data.mem_pct !== undefined)
            root.memPct = Math.max(0, Math.min(100, parseInt(data.mem_pct) || 0))
          if (data.mem_used)
            root.memUsed = String(data.mem_used)
          if (data.mem_avail)
            root.memAvail = String(data.mem_avail)
          if (data.mem_total)
            root.memTotal = String(data.mem_total)
          if (data.swap_used)
            root.swapUsed = String(data.swap_used)
          if (data.swap_total)
            root.swapTotal = String(data.swap_total)
          if (data.swap_pct !== undefined)
            root.swapPct = Math.max(0, Math.min(100, parseInt(data.swap_pct) || 0))
          if (data.cpu_temp)
            root.cpuTemp = String(data.cpu_temp)
          if (data.gpu_temp)
            root.gpuTemp = String(data.gpu_temp)
          if (data.nvme_temp)
            root.nvmeTemp = String(data.nvme_temp)
          if (data.fan1_rpm !== undefined)
            root.fan1Rpm = parseInt(data.fan1_rpm) || 0
          if (data.fan2_rpm !== undefined)
            root.fan2Rpm = parseInt(data.fan2_rpm) || 0
          if (Array.isArray(data.top_mem))
            root.topMem = data.top_mem
          root.fanControl = !!data.fan_control
          if (root.selectedProc >= root.topMem.length)
            root.selectedProc = Math.max(0, root.topMem.length - 1)
        } catch (e) {
          root.fetchError = "bad stats json"
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛 " + root.memUsed + "G " + root.memPct + "%  " + root.cpuTemp + "  " + (root.currentMode === "high" ? "H" : (root.currentMode === "med" ? "M" : "L"))
    fontSize: Style.font.bodySmall
    active: root.memPct >= 80 || root.currentMode === "high"
    activeColor: root.memPct >= 85 ? root.urgent : (root.bar ? root.bar.urgent : Color.urgent)
    tooltipText: "RAM " + root.memUsed + "/" + root.memTotal + "G · CPU " + root.cpuLoad + "% " + root.cpuTemp + " · GPU " + root.gpuTemp + " · SSD " + root.nvmeTemp + (root.fanControl ? " · right-click cycles fan" : " · fan control unavailable")
    horizontalMargin: 6.0
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton)
        root.cycleMode()
      else {
        root.refresh()
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_J) {
        root.selectedProc = Math.min(root.topMem.length - 1, root.selectedProc + 1)
        event.accepted = true
      } else if (event.key === Qt.Key_K) {
        root.selectedProc = Math.max(0, root.selectedProc - 1)
        event.accepted = true
      } else if (event.key === Qt.Key_X && root.topMem[root.selectedProc]) {
        root.killProcess(root.topMem[root.selectedProc].pid)
        event.accepted = true
      }
    }

    Column {
      id: mainColumn
      width: parent.width
      spacing: Style.space(10)
      padding: Style.space(14)

      RowLayout {
        width: parent.width
        Text {
          text: "Resource & Fan"
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Item {
          Layout.fillWidth: true
        }
        Text {
          visible: root.fetchError.length > 0
          text: root.fetchError
          color: root.urgent
          font.pixelSize: Style.font.bodySmall
        }
        Rectangle {
          visible: root.fetchError.length === 0
          width: modeLabel.implicitWidth + 14
          height: 22
          radius: 11
          color: root.currentMode === "high" ? root.urgent : (root.currentMode === "med" ? root.accent : root.muted)
          Text {
            id: modeLabel
            anchors.centerIn: parent
            text: root.fanControl ? root.currentMode.toUpperCase() : "READ"
            color: Color.background
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          MouseArea {
            anchors.fill: parent
            enabled: root.fanControl
            cursorShape: Qt.PointingHandCursor
            onClicked: root.cycleMode()
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.fg
        opacity: 0.12
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        RowLayout {
          width: parent.width
          Text {
            text: "Memory"
            color: root.fg
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            text: root.memUsed + " / " + root.memTotal + " GB (" + root.memPct + "%)"
            color: root.memColor()
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
        }
        Rectangle {
          width: parent.width
          height: Style.space(7)
          radius: 3.5
          color: root.fg
          opacity: 0.15
          Rectangle {
            width: Math.max(4, parent.width * (root.memPct / 100.0))
            height: parent.height
            radius: 3.5
            color: root.memColor()
          }
        }
        Text {
          text: "avail " + root.memAvail + "G · swap " + root.swapUsed + "/" + root.swapTotal + "G"
          color: root.muted
          font.pixelSize: Style.font.bodySmall
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.topMem && root.topMem.length > 0
        Text {
          text: "TOP MEMORY  ·  j/k  x kill"
          color: root.muted
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Repeater {
          model: root.topMem
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: Style.space(26)
            radius: Style.space(4)
            color: index === root.selectedProc ? Style.selectedFillFor(root.fg, Color.accent) : "transparent"
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedProc = index
            }
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              Text {
                text: modelData.name || "unknown"
                color: root.fg
                font.bold: true
                font.pixelSize: Style.font.bodySmall
                Layout.preferredWidth: 130
                elide: Text.ElideRight
              }
              Text {
                text: "PID " + (modelData.pid || "")
                color: root.muted
                font.pixelSize: Style.font.bodySmall
              }
              Item {
                Layout.fillWidth: true
              }
              Text {
                text: (modelData.mem_mb || 0) + " MB"
                color: root.fg
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: 18
                height: 18
                radius: 4
                color: root.urgent
                Text {
                  anchors.centerIn: parent
                  text: "x"
                  color: Color.background
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.killProcess(modelData.pid)
                }
              }
            }
          }
        }
      }

      Text {
        visible: !root.topMem || root.topMem.length === 0
        text: "No heavy processes"
        color: root.muted
        font.pixelSize: Style.font.bodySmall
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.fg
        opacity: 0.12
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: "CPU " + root.cpuLoad + "%  " + root.cpuTemp + " · GPU " + root.gpuTemp + " · SSD " + root.nvmeTemp
          color: root.fg
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: "Fans " + root.fan1Rpm + " / " + root.fan2Rpm + " RPM"
          color: root.fg
          font.pixelSize: Style.font.bodySmall
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        Repeater {
          model: [
            {
              "id": "low",
              "label": "Low"
            },
            {
              "id": "med",
              "label": "Med"
            },
            {
              "id": "high",
              "label": "High"
            }
          ]
          delegate: Rectangle {
            required property var modelData
            width: (parent.width - Style.space(16)) / 3
            height: Style.space(36)
            radius: Style.space(6)
            opacity: root.fanControl ? 1 : 0.4
            color: root.currentMode === modelData.id ? root.fg : "transparent"
            border.color: root.fg
            border.width: 1
            Text {
              anchors.centerIn: parent
              text: modelData.label
              color: root.currentMode === modelData.id ? Color.background : root.fg
              font.bold: true
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              enabled: root.fanControl
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setMode(modelData.id)
            }
          }
        }
      }
    }
  }
}

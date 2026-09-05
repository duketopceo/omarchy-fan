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

  property string currentMode: "auto"
  property string customName: "balanced"
  property int cpuLoad: 0
  property string cpuName: "CPU"
  property var cpuCores: []
  property int memPct: 0
  property string memUsed: "--"
  property string memAvail: "--"
  property string memTotal: "--"
  property string swapUsed: "--"
  property string swapTotal: "--"
  property int swapPct: 0
  property string ramInfo: ""
  property string cpuTemp: "--"
  property string gpuName: "GPU"
  property int gpuLoad: -1
  property string gpuTemp: "--"
  property string nvmeTemp: "--"
  property int fan1Rpm: 0
  property int fan2Rpm: 0
  property var topMem: []
  property var disks: []
  property var fanCurve: []
  property bool isRefreshing: false
  property string fetchError: ""
  property bool fanControl: false
  property int selectedProc: 0

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: Color.urgent
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
    Quickshell.execDetached(["python3", root.pluginRoot + "/bin/omarchy-fan-set", mode])
    refreshTimer.restart()
  }

  function setCustom(name) {
    if (!root.fanControl)
      return
    currentMode = "custom"
    customName = name
    Quickshell.execDetached(["python3", root.pluginRoot + "/bin/omarchy-fan-set", "custom", name])
    refreshTimer.restart()
  }

  function cycleMode() {
    if (!root.fanControl)
      return
    if (currentMode === "auto")
      setMode("low")
    else if (currentMode === "low")
      setMode("med")
    else if (currentMode === "med")
      setMode("high")
    else if (currentMode === "high")
      setMode("custom")
    else
      setMode("auto")
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

  function btop() {
    if (bar)
      bar.run("omarchy-launch-or-focus-tui btop")
    root.close()
  }

  function memColor() {
    if (root.memPct >= 85)
      return root.urgent
    if (root.memPct >= 70)
      return root.accent
    return root.fg
  }

  function tempColor(tempStr) {
    var t = parseInt(tempStr)
    if (isNaN(t))
      return root.muted
    if (t >= 85)
      return root.urgent
    if (t >= 65)
      return root.accent
    return root.fg
  }

  function levelColor(value, warn, crit) {
    if (value < 0 || isNaN(value))
      return root.muted
    if (value >= crit)
      return root.urgent
    if (value >= warn)
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
          if (data.cpu_name)
            root.cpuName = String(data.cpu_name)
          if (data.cpu_load !== undefined)
            root.cpuLoad = Math.max(0, Math.min(100, parseInt(data.cpu_load) || 0))
          if (Array.isArray(data.cpu_cores))
            root.cpuCores = data.cpu_cores
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
          if (data.ram_info)
            root.ramInfo = String(data.ram_info)
          if (data.cpu_temp)
            root.cpuTemp = String(data.cpu_temp)
          if (data.gpu_name)
            root.gpuName = String(data.gpu_name)
          if (data.gpu_load !== undefined) {
            var gl = parseInt(data.gpu_load)
            root.gpuLoad = isNaN(gl) ? -1 : Math.max(0, Math.min(100, gl))
          }
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
          if (Array.isArray(data.disks))
            root.disks = data.disks
          if (Array.isArray(data.fan_curve))
            root.fanCurve = data.fan_curve
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
    text: "󰍛 " + root.memUsed + "G " + root.memPct + "%  " + root.cpuTemp + "  " + (root.currentMode === "auto" ? "A" : (root.currentMode === "high" ? "H" : (root.currentMode === "med" ? "M" : (root.currentMode === "custom" ? "C" : "L"))))
    fontSize: Style.font.bodySmall
    active: root.memPct >= 80 || root.currentMode === "high" || (root.currentMode === "auto" && parseInt(root.cpuTemp) >= 60)
    activeColor: root.memPct >= 85 || parseInt(root.cpuTemp) >= 65 ? root.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: "RAM " + root.memUsed + "/" + root.memTotal + "G · CPU " + root.cpuLoad + "% " + root.cpuTemp + " · GPU " + root.gpuTemp + " · SSD " + root.nvmeTemp + (root.fanControl ? " · right-click cycles fan · middle btop" : " · fan control unavailable")
    horizontalMargin: 6.0
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton)
        root.cycleMode()
      else if (buttonCode === Qt.MiddleButton)
        root.btop()
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
    contentWidth: panel.fittedContentWidth(Style.space(340), 420)
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, 720)
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
      } else if (event.key === Qt.Key_B) {
        root.btop()
        event.accepted = true
      }
    }

    Column {
      id: mainColumn
      width: parent.width
      spacing: Style.space(8)

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
          color: root.currentMode === "high" || (root.currentMode === "custom" && root.customName === "performance") ? root.urgent :
                 (root.currentMode === "med" || (root.currentMode === "custom" && root.customName === "balanced") ? root.accent : root.muted)
          Text {
            id: modeLabel
            anchors.centerIn: parent
            text: root.fanControl ? (root.currentMode === "custom" ? root.customName.toUpperCase() : root.currentMode.toUpperCase()) : "READ"
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

      PanelSeparator { foreground: root.fg }

      Column {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: root.cpuName
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        RowLayout {
          width: parent.width
          Text {
            text: "CPU " + root.cpuLoad + "%"
            color: root.levelColor(root.cpuLoad, 70, 90)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            text: root.cpuTemp
            color: root.tempColor(root.cpuTemp)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }
        Rectangle {
          width: parent.width
          height: Style.space(7)
          radius: 3.5
          color: root.fg
          opacity: 0.15
          Rectangle {
            width: Math.max(4, parent.width * (root.cpuLoad / 100.0))
            height: parent.height
            radius: 3.5
            color: root.levelColor(root.cpuLoad, 70, 90)
          }
        }
      }

      Column {
        width: parent.width
        visible: root.cpuCores.length > 0
        spacing: Style.space(6)
        Text {
          text: root.cpuCores.length + " CORES"
          color: root.muted
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Grid {
          id: coresGrid
          width: parent.width
          columns: root.cpuCores.length <= 8 ? 2 : (root.cpuCores.length <= 16 ? 4 : 6)
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(4)
          Repeater {
            model: root.cpuCores
            delegate: Rectangle {
              required property var modelData
              width: (parent.width - parent.columnSpacing * (parent.columns - 1)) / parent.columns
              height: Style.space(20)
              radius: Style.space(3)
              color: "transparent"
              border.color: root.fg
              border.width: 1
              opacity: 0.9
              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                color: root.levelColor(modelData.percent, 60, 80)
                opacity: 0.35
                radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, modelData.percent / 100.0))
              }
              Text {
                anchors.centerIn: parent
                text: "C" + modelData.core
                color: root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }

      PanelSeparator { foreground: root.fg }

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
          text: "avail " + root.memAvail + "G · swap " + root.swapUsed + "/" + root.swapTotal + "G" + (root.ramInfo ? " · " + root.ramInfo : "")
          color: root.muted
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: root.fg }

      Column {
        width: parent.width
        visible: root.gpuName !== "GPU" || root.gpuLoad >= 0 || root.gpuTemp !== "--"
        spacing: Style.space(6)
        RowLayout {
          width: parent.width
          Text {
            text: root.gpuName
            color: root.fg
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            text: (root.gpuLoad >= 0 ? root.gpuLoad + "% " : "") + root.gpuTemp
            color: root.tempColor(root.gpuTemp)
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
        }
        Rectangle {
          visible: root.gpuLoad >= 0
          width: parent.width
          height: Style.space(7)
          radius: 3.5
          color: root.fg
          opacity: 0.15
          Rectangle {
            width: Math.max(4, parent.width * (root.gpuLoad / 100.0))
            height: parent.height
            radius: 3.5
            color: root.levelColor(root.gpuLoad, 70, 90)
          }
        }
      }

      PanelSeparator {
        visible: root.disks.length > 0
        foreground: root.fg
      }

      Column {
        width: parent.width
        visible: root.disks.length > 0
        spacing: Style.space(6)
        Text {
          text: "Storage"
          color: root.fg
          font.bold: true
          font.pixelSize: Style.font.bodySmall
        }
        Column {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            model: root.disks
            delegate: Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(2)
              RowLayout {
                width: parent.width
                Text {
                  text: modelData.mount
                  color: root.fg
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: 100
                  elide: Text.ElideRight
                }
                Item {
                  Layout.fillWidth: true
                }
                Text {
                  text: modelData.used_gb + " / " + modelData.total_gb + "G (" + modelData.percent + "%)"
                  color: root.levelColor(modelData.percent, 80, 95)
                  font.pixelSize: Style.font.caption
                }
              }
              Rectangle {
                width: parent.width
                height: Style.space(5)
                radius: 2.5
                color: root.fg
                opacity: 0.15
                Rectangle {
                  width: Math.max(4, parent.width * (modelData.percent / 100.0))
                  height: parent.height
                  radius: 2.5
                  color: root.levelColor(modelData.percent, 80, 95)
                }
              }
            }
          }
        }
      }

      PanelSeparator { foreground: root.fg }

      Column {
        width: parent.width
        spacing: Style.space(8)
        Text {
          text: "Fans " + root.fan1Rpm + " / " + root.fan2Rpm + " RPM"
          color: root.fg
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: ["auto", "low", "med", "high", "custom"]
            delegate: Rectangle {
              required property string modelData
              width: (parent.width - Style.space(24)) / 5
              height: Style.space(34)
              radius: Style.space(6)
              opacity: root.fanControl ? 1 : 0.4
              color: root.currentMode === modelData ? root.fg : "transparent"
              border.color: root.fg
              border.width: 1
              Text {
                anchors.centerIn: parent
                text: modelData === "auto" ? "Auto" : (modelData === "low" ? "Low" : (modelData === "med" ? "Med" : (modelData === "high" ? "High" : "Cust")))
                color: root.currentMode === modelData ? Color.background : root.fg
                font.bold: true
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                enabled: root.fanControl
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setMode(modelData)
              }
            }
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.currentMode === "custom"
          Repeater {
            model: ["silent", "balanced", "performance"]
            delegate: Rectangle {
              required property string modelData
              width: (parent.width - Style.space(12)) / 3
              height: Style.space(28)
              radius: Style.space(6)
              opacity: root.fanControl ? 1 : 0.4
              color: root.customName === modelData ? root.accent : "transparent"
              border.color: root.fg
              border.width: 1
              Text {
                anchors.centerIn: parent
                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                color: root.customName === modelData ? Color.background : root.fg
                font.bold: true
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                enabled: root.fanControl
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setCustom(modelData)
              }
            }
          }
        }
        Canvas {
          id: curveCanvas
          visible: root.currentMode === "custom" && root.fanCurve.length > 1
          width: parent.width
          height: Style.space(70)
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!root.fanCurve || root.fanCurve.length < 2)
              return
            var pad = 8
            var cw = width - pad * 2
            var ch = height - pad * 2
            var tMax = 100
            var pMax = 255
            var pts = root.fanCurve

            ctx.strokeStyle = "rgba(" + Math.round(root.fg.r * 255) + "," + Math.round(root.fg.g * 255) + "," + Math.round(root.fg.b * 255) + ",0.15)"
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(pad, pad)
            ctx.lineTo(pad, height - pad)
            ctx.lineTo(width - pad, height - pad)
            ctx.stroke()

            ctx.strokeStyle = root.accent
            ctx.lineWidth = 2
            ctx.beginPath()
            for (var i = 0; i < pts.length; i++) {
              var t = pts[i][0]
              var p = pts[i][1]
              var x = pad + (t / tMax) * cw
              var y = (height - pad) - (p / pMax) * ch
              if (i === 0)
                ctx.moveTo(x, y)
              else
                ctx.lineTo(x, y)
            }
            ctx.stroke()

            var ct = parseInt(root.cpuTemp)
            if (!isNaN(ct)) {
              ctx.fillStyle = root.urgent
              ctx.beginPath()
              var cx = pad + Math.min(1, Math.max(0, ct / tMax)) * cw
              ctx.arc(cx, height - pad - 4, 3, 0, Math.PI * 2)
              ctx.fill()
            }
          }
          Connections {
            target: root
            function onFanCurveChanged() {
              if (curveCanvas.visible)
                curveCanvas.requestPaint()
            }
          }
        }
      }

      PanelSeparator { foreground: root.fg }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.topMem && root.topMem.length > 0
        RowLayout {
          width: parent.width
          Text {
            text: "TOP MEMORY  ·  j/k  x kill"
            color: root.muted
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            text: "b btop"
            color: root.muted
            font.pixelSize: Style.font.caption
          }
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
                Layout.preferredWidth: 120
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
    }
  }
}

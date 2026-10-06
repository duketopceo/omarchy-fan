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
  property string gpuLoadReason: ""
  property string gpuTemp: "--"
  property real gpuPowerW: -1
  property var gpuClients: []
  property string nvmeTemp: "--"
  property int fan1Rpm: 0
  property int fan2Rpm: 0
  property var topMem: []
  property var disks: []
  property var fanCurve: []
  property bool isRefreshing: false
  property string fetchError: ""
  // Last stderr chunk from the stats helper — appended to fetchError when
  // the process exits non-zero so a crash carries diagnostics.
  property string statsStderr: ""
  // Fan control is owned by the omarchy-fan-helper package (root, from
  // /usr/lib/omarchy-fan). The plugin never installs or elevates it: it only
  // reads the helper's status and asks for a package install/update.
  readonly property string expectedHelperVersion: "1.0.1"
  // "missing" | "outdated" | "ok"
  property string helperState: "missing"
  property string helperVersion: ""
  property bool helperControllable: false
  property string helperMode: ""
  // A mode the user just requested; the helper status lags by up to one tick,
  // so readHelperStatus must not revert currentMode until it catches up.
  property string pendingMode: ""
  property real pendingUntil: 0
  readonly property bool fanControl: root.helperState === "ok" && root.helperControllable
  readonly property bool helperModeActive: root.helperState === "ok" && root.helperMode.length > 0
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

  // Absolute interpreter: a PATH-preceding shadow "python3" must never run
  // inside this long-lived shell process.
  readonly property string py: "/usr/bin/python3"
  // XDG_RUNTIME_DIR must survive the scrub: the collector resolves
  // $XDG_RUNTIME_DIR/omarchy-fan/current_fan_mode — the same path
  // omarchy-fan-set writes (full env) and the daemon reads. Scrubbing it
  // makes the helper fall back to ~/.local/run, so fan_mode reads "auto"
  // forever and the badge/presets/right-click cycling go dead.
  readonly property var procEnv: ({
    "PATH": "/usr/bin:/bin",
    "HOME": null,
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR"),
    "LANG": null,
    "LC_ALL": "C"
  })

  // loaded=false: the status file is gone (helper not installed or stopped).
  function readHelperStatus(loaded) {
    var raw = ""
    if (loaded) {
      try {
        raw = String(helperStatusFile.text() || "")
      } catch (e) {
        raw = ""
      }
    }
    var data = null
    if (raw.length > 0 && raw.length < 4096) {
      try {
        data = JSON.parse(raw)
      } catch (e2) {
        data = null
      }
    }
    if (!data || typeof data !== "object") {
      root.helperState = "missing"
      root.helperVersion = ""
      root.helperControllable = false
      root.helperMode = ""
      return
    }
    root.helperVersion = clipStr(data.version, 24)
    root.helperState = root.helperVersion === root.expectedHelperVersion ? "ok" : "outdated"
    root.helperControllable = data.controllable === true
    root.helperMode = clipStr(data.mode, 24).trim()
    if (root.pendingMode.length > 0 && (root.helperMode === root.pendingMode || Date.now() > root.pendingUntil))
      root.pendingMode = ""
    if (root.helperModeActive && root.pendingMode.length === 0)
      root.currentMode = root.helperMode
  }

  function helperHint() {
    if (root.helperState === "missing")
      return "Fan control: install the omarchy-fan-helper package and run 'systemctl enable --now omarchy-fan-daemon.service'"
    if (root.helperState === "outdated")
      return "Fan control: update the omarchy-fan-helper package (have " + (root.helperVersion || "?") + ", need " + root.expectedHelperVersion + ")"
    if (!root.helperControllable)
      return "Fan control: no writable fan target here"
    return "Helper " + root.helperVersion
  }

  function setMode(mode) {
    // "auto" is always safe to write, so it bypasses the fanControl guard
    // whenever a helper is present (e.g. version drift with a pinned preset).
    if (!mode || !(root.fanControl || (mode === "auto" && root.helperState !== "missing")))
      return
    currentMode = mode
    root.pendingMode = mode
    root.pendingUntil = Date.now() + 6000
    Quickshell.execDetached([root.py, root.pluginRoot + "/bin/omarchy-fan-set", mode])
    refreshTimer.restart()
  }

  function setCustom(name) {
    if (!root.fanControl)
      return
    currentMode = "custom"
    root.pendingMode = "custom"
    root.pendingUntil = Date.now() + 6000
    customName = name
    Quickshell.execDetached([root.py, root.pluginRoot + "/bin/omarchy-fan-set", "custom", name])
    refreshTimer.restart()
  }

  function cycleMode() {
    if (!root.fanControl)
      return
    var from = root.pendingMode.length > 0 ? root.pendingMode : currentMode
    if (from === "auto")
      setMode("low")
    else if (from === "low")
      setMode("med")
    else if (from === "med")
      setMode("high")
    else if (from === "high")
      setMode("custom")
    else
      setMode("auto")
  }

  function killProcess(pid) {
    if (!pid || pid <= 1)
      return
    Quickshell.execDetached([root.py, root.pluginRoot + "/bin/kill_proc.py", pid.toString()])
    refreshTimer.restart()
  }

  // Cap + normalize collector-provided strings before they reach Text sinks:
  // process names and mount paths are locally controlled and must never carry
  // markup or runaway length into the persistent shell.
  function clipStr(v, n) {
    return String(v == null ? "" : v).replace(/[\x00-\x1f\x7f-\x9f<>]/g, " ").slice(0, n || 80)
  }

  function refresh() {
    helperStatusFile.reload()
    if (!statusProc.running) {
      root.isRefreshing = true
      statusProc.running = true
      statusDeadline.restart()
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
    command: [root.py, root.pluginRoot + "/bin/system_monitor_stats.py"]
    clearEnvironment: true
    environment: root.procEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        statusDeadline.stop()
        root.isRefreshing = false
        try {
          if (!text || text.trim().length === 0) {
            root.fetchError = "empty stats"
            return
          }
          if (text.length > 300000) {
            root.fetchError = "oversized stats payload"
            return
          }
          var data = JSON.parse(text)
          if (data.ok === false) {
            root.fetchError = data.error || "stats failed"
            return
          }
          root.fetchError = ""
          // The helper's effective mode wins: an expired preset shows as auto.
          if (data.fan_mode && !root.helperModeActive)
            root.currentMode = clipStr(data.fan_mode, 24).trim()
          if (data.cpu_name)
            root.cpuName = clipStr(data.cpu_name)
          if (data.cpu_load !== undefined)
            root.cpuLoad = Math.max(0, Math.min(100, parseInt(data.cpu_load) || 0))
          if (Array.isArray(data.cpu_cores))
            root.cpuCores = data.cpu_cores
          if (data.mem_pct !== undefined)
            root.memPct = Math.max(0, Math.min(100, parseInt(data.mem_pct) || 0))
          if (data.mem_used)
            root.memUsed = clipStr(data.mem_used, 24)
          if (data.mem_avail)
            root.memAvail = clipStr(data.mem_avail, 24)
          if (data.mem_total)
            root.memTotal = clipStr(data.mem_total, 24)
          if (data.swap_used)
            root.swapUsed = clipStr(data.swap_used, 24)
          if (data.swap_total)
            root.swapTotal = clipStr(data.swap_total, 24)
          if (data.swap_pct !== undefined)
            root.swapPct = Math.max(0, Math.min(100, parseInt(data.swap_pct) || 0))
          if (data.ram_info)
            root.ramInfo = clipStr(data.ram_info)
          if (data.cpu_temp)
            root.cpuTemp = clipStr(data.cpu_temp, 16)
          if (data.gpu_name)
            root.gpuName = clipStr(data.gpu_name)
          if (data.gpu_load !== undefined) {
            var gl = parseInt(data.gpu_load)
            root.gpuLoad = isNaN(gl) ? -1 : Math.max(0, Math.min(100, gl))
          }
          if (data.gpu_load_reason !== undefined)
            root.gpuLoadReason = clipStr(data.gpu_load_reason, 80)
          if (data.gpu_temp)
            root.gpuTemp = clipStr(data.gpu_temp, 16)
          root.gpuPowerW = (typeof data.gpu_power_w === "number") ? data.gpu_power_w : -1
          if (Array.isArray(data.gpu_clients))
            root.gpuClients = data.gpu_clients.slice(0, 24).map(function(c) {
              c.name = clipStr(c.name, 32)
              return c
            })
          if (data.nvme_temp)
            root.nvmeTemp = clipStr(data.nvme_temp, 16)
          if (data.fan1_rpm !== undefined)
            root.fan1Rpm = parseInt(data.fan1_rpm) || 0
          if (data.fan2_rpm !== undefined)
            root.fan2Rpm = parseInt(data.fan2_rpm) || 0
          if (Array.isArray(data.top_mem))
            root.topMem = data.top_mem.slice(0, 32).map(function(p) {
              p.name = clipStr(p.name, 48)
              return p
            })
          if (Array.isArray(data.disks))
            root.disks = data.disks.slice(0, 24).map(function(d) {
              d.mount = clipStr(d.mount, 64)
              return d
            })
          if (Array.isArray(data.fan_curve))
            root.fanCurve = data.fan_curve
          if (root.selectedProc >= root.topMem.length)
            root.selectedProc = Math.max(0, root.topMem.length - 1)
        } catch (e) {
          root.fetchError = "bad stats json"
        }
      }
    }
    // A collector crash writes its traceback to stderr — collect it so a
    // dead helper surfaces real diagnostics instead of a bare exit code.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        root.statsStderr = err.substring(0, 200)
        if (err)
          console.warn("system_monitor_stats stderr: " + err.substring(0, 500))
      }
    }
    onExited: function (code) {
      statusDeadline.stop()
      root.isRefreshing = false
      if (code !== 0 && root.fetchError.length === 0)
        root.fetchError = root.statsStderr.length > 0
          ? "stats helper failed: " + root.statsStderr
          : "stats helper exited " + code
      root.statsStderr = ""
    }
  }

  // Hard whole-job deadline: a stuck collector is killed and reaped, never
  // left running past one refresh interval.
  Timer {
    id: statusDeadline
    interval: 9000
    onTriggered: {
      if (statusProc.running) {
        statusProc.signal(9)
        root.isRefreshing = false
        root.fetchError = "stats timeout"
      }
    }
  }

  // Root-owned status from the packaged helper (version, mode, controllable).
  // Re-read on every stats refresh; a read is spawn-free.
  FileView {
    id: helperStatusFile
    path: "/run/omarchy-fan/status.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.readHelperStatus(true)
    onLoadFailed: root.readHelperStatus(false)
  }

  // Shell heartbeat for the helper: fixed presets expire when it is older than
  // 120 s, so the fans never stay pinned after the shell is gone. Written in
  // place (no process spawn) every 30 s, independent of panel visibility or
  // screen lock. The directory is created by omarchy-fan-set when a mode is
  // chosen; before that there is no preset to keep alive.
  readonly property string heartbeatPath: {
    var base = Quickshell.env("XDG_RUNTIME_DIR")
    return base ? base + "/omarchy-fan/heartbeat" : ""
  }

  FileView {
    id: heartbeatFile
    path: root.heartbeatPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: heartbeatTimer
    interval: 30000
    running: root.heartbeatPath.length > 0 && root.fanControl
    repeat: true
    triggeredOnStart: true
    onTriggered: heartbeatFile.setText(String(Math.floor(Date.now() / 1000)))
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
    text: "󰍛 " + root.memUsed + "G " + root.memPct + "% " + root.cpuTemp + " 󰈐 " + (root.currentMode === "auto" ? "A" : (root.currentMode === "high" ? "H" : (root.currentMode === "med" ? "M" : (root.currentMode === "custom" ? "C" : "L"))))
    fontSize: Style.font.bodySmall
    active: root.memPct >= 80 || root.currentMode === "high" || (root.currentMode === "auto" && parseInt(root.cpuTemp) >= 60)
    activeColor: root.memPct >= 85 || parseInt(root.cpuTemp) >= 65 ? root.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: "RAM " + root.memUsed + "/" + root.memTotal + "G · CPU " + root.cpuLoad + "% " + root.cpuTemp + " · GPU " + root.gpuTemp + (root.gpuPowerW >= 0 ? " " + root.gpuPowerW.toFixed(0) + "W" : "") + (root.gpuClients.length > 0 ? " (" + root.gpuClients.length + " procs)" : "") + " · SSD " + root.nvmeTemp + (root.fanControl ? " · right-click cycles fan · middle btop" : " · fan control unavailable")
    horizontalMargin: 4.0
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
          textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
          textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
          textFormat: Text.PlainText
          text: "avail " + root.memAvail + "G · swap " + root.swapUsed + "/" + root.swapTotal + "G" + (root.ramInfo ? " · " + root.ramInfo : "")
          color: root.muted
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator { foreground: root.fg }

      Column {
        width: parent.width
        visible: root.gpuName !== "GPU" || root.gpuLoad >= 0 || root.gpuTemp !== "--" || root.gpuLoadReason !== ""
        spacing: Style.space(6)
        RowLayout {
          width: parent.width
          Text {
            text: root.gpuName
            textFormat: Text.PlainText
            color: root.fg
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            text: (root.gpuLoad >= 0 ? root.gpuLoad + "% " : "") + root.gpuTemp
            textFormat: Text.PlainText
            color: root.tempColor(root.gpuTemp)
            font.bold: true
            font.pixelSize: Style.font.bodySmall
          }
        }
        Text {
          visible: root.gpuLoad < 0 && root.gpuLoadReason !== ""
          width: parent.width
          text: root.gpuLoadReason
          textFormat: Text.PlainText
          color: root.muted
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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
        Text {
          visible: root.gpuPowerW >= 0 || root.gpuClients.length > 0
          width: parent.width
          text: (root.gpuPowerW >= 0 ? "pkg " + root.gpuPowerW.toFixed(1) + " W" : "")
                + (root.gpuPowerW >= 0 && root.gpuClients.length > 0 ? " · " : "")
                + (root.gpuClients.length > 0
                   ? root.gpuClients.length + " gpu proc" + (root.gpuClients.length > 1 ? "s" : "")
                     + ": " + root.gpuClients.slice(0, 4).map(function(c) { return c.name }).join(", ")
                     + (root.gpuClients.length > 4 ? "…" : "")
                   : "")
          textFormat: Text.PlainText
          color: root.muted
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          wrapMode: Text.NoWrap
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
          textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
                  textFormat: Text.PlainText
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
        RowLayout {
          width: parent.width
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "Fans " + root.fan1Rpm + " / " + root.fan2Rpm + " RPM"
            color: root.fg
            font.pixelSize: Style.font.bodySmall
          }
        }
        Text {
          width: parent.width
          text: root.helperHint()
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.fanControl ? root.muted : root.accent
          font.pixelSize: Style.font.caption
        }
        Rectangle {
          visible: !root.fanControl && root.helperState !== "missing"
          width: parent.width
          height: Style.space(34)
          radius: Style.space(6)
          color: "transparent"
          border.color: root.fg
          border.width: 1
          Text {
            anchors.centerIn: parent
            text: "Reset to auto"
            textFormat: Text.PlainText
            color: root.fg
            font.bold: true
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setMode("auto")
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.fanControl
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
                textFormat: Text.PlainText
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
          visible: root.fanControl && root.currentMode === "custom"
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
                textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            text: "TOP MEMORY  ·  j/k  x kill"
            color: root.muted
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Item {
            Layout.fillWidth: true
          }
          Text {
            textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                color: root.fg
                font.bold: true
                font.pixelSize: Style.font.bodySmall
                Layout.preferredWidth: 120
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                text: "PID " + (modelData.pid || "")
                color: root.muted
                font.pixelSize: Style.font.bodySmall
              }
              Item {
                Layout.fillWidth: true
              }
              Text {
                text: (modelData.mem_mb || 0) + " MB"
                textFormat: Text.PlainText
                color: root.fg
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: 18
                height: 18
                radius: 4
                color: root.urgent
                Text {
                  textFormat: Text.PlainText
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

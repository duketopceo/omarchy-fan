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
  // '/' find mode: procFilter edits live; findResults is filled by the
  // --find run of the stats helper (searches all processes, not just top_mem).
  property string procFilter: ""
  property bool findMode: false
  property var findResults: []
  property string findInFlight: ""
  // Armed-kill confirm (KTD4): first activation pins the target pid and turns
  // its row into a "Kill …?" confirm; a second activation within 3 s sends
  // SIGTERM. Keyed by pid so a list re-sort can't silently retarget it.
  property int armedPid: -1
  // Hover identity overlay state (KTD3): which proc the pointer sits on and
  // which row item the tip anchors to inside the processes card.
  property var hoverProcData: null
  property Item hoverProcRow: null
  // Additive collector keys (KTD6): byte/sec rates, -1 when the collector
  // doesn't emit them yet; the matching mini-cards hide themselves.
  property real netDownBps: -1
  property real netUpBps: -1
  property real diskReadBps: -1
  property real diskWriteBps: -1
  // ~60-sample history rings feeding the per-card sparklines when present.
  property var histCpu: []
  property var histTemp: []
  property var histMem: []
  // Per-card drill-down state (chevron toggles): each card exposes its own
  // consumers — procs under memory/cpu/gpu, per-iface/per-dev rates under
  // net/disk. Drill kills share armedPid with the main process list.
  property bool openMem: false
  property bool openCpu: false
  property bool openGpu: false
  property bool openNet: false
  property bool openDisk: false
  property var topCpu: []
  property var netIfaces: []
  property var diskDevs: []

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color surface: Color.popups.background
  // Identity-dot palette: theme-derived only (no hardcoded hex). Cycled per
  // row so adjacent processes read as distinct; cpu>=50 overrides to urgent.
  readonly property var dotPalette: [
    accent,
    Qt.lighter(accent, 1.4),
    fg,
    Qt.darker(accent, 1.3)
  ]
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

  // Armed-confirm kill (KTD4): every kill activation — the row × button, `x`,
  // `Ctrl+X` — goes through here. First hit arms the pid and the row swaps
  // to an in-place "Kill {alias} · {comm} · pid n?" confirm; a second hit on
  // the SAME pid within the 3 s window calls killProcess(). Different pid
  // re-arms to the new target. Esc / filter edits / panel close disarm.
  function armKill(proc) {
    if (!proc)
      return
    var pid = parseInt(proc.pid)
    if (isNaN(pid) || pid <= 1)
      return
    if (root.armedPid === pid) {
      root.disarmKill()
      root.killProcess(pid)
      return
    }
    root.armedPid = pid
    armTimer.restart()
  }

  function disarmKill() {
    armTimer.stop()
    root.armedPid = -1
  }

  // Kill tiers: app- and session-scoped procs are user-launched apps — a
  // single activation kills them outright. Services and anything without a
  // classifiable unit take the armed "Kill …?" path so a stray click can't
  // drop docker/wayland-wm/sshd on the floor.
  function killTier(p) {
    var u = p && p.unit ? String(p.unit) : ""
    return (u.indexOf("app-") === 0 || u.indexOf("session-") === 0) ? "app" : "service"
  }

  // Row field accessors tolerant of both collector generations (KTD6): the
  // pre-2.5 keys (cpu_pct/mem_mb) and the additive contract (cpu/mem/rss).
  function procCpu(p) {
    if (!p)
      return -1
    var v = p.cpu !== undefined ? p.cpu : p.cpu_pct
    var n = Number(v)
    return isFinite(n) ? n : -1
  }

  function procMemText(p) {
    if (!p)
      return "--"
    var v = p.mem_mb !== undefined ? p.mem_mb : (p.mem !== undefined ? p.mem : p.rss)
    if (v === undefined || v === null)
      return "--"
    var n = Number(v)
    if (!isFinite(n))
      return clipStr(v, 12)
    if (n > 262144)
      n = n / 1024 // arrived as KB-scale rss
    return (n >= 100 ? Math.round(n) : Math.round(n * 10) / 10) + " MB"
  }

  // Byte/sec rate → compact label; "--" for absent/negative sources (R6).
  function fmtRate(bps) {
    var n = Number(bps)
    if (!isFinite(n) || n < 0)
      return "--"
    if (n >= 1073741824)
      return (n / 1073741824).toFixed(1) + " GB/s"
    if (n >= 1048576)
      return (n / 1048576).toFixed(1) + " MB/s"
    if (n >= 1024)
      return (n / 1024).toFixed(1) + " KB/s"
    return Math.round(n) + " B/s"
  }

  // Rate field normalization: the collector may emit *_bps (bytes/sec) or
  // *_kbps (kilo*bytes*/sec) key spellings — accept either, always yield bps.
  function bpsField(obj, bpsKey, kbpsKey) {
    if (!obj || typeof obj !== "object")
      return -1
    if (obj[bpsKey] !== undefined) {
      var n = Number(obj[bpsKey])
      return isFinite(n) ? Math.max(0, n) : -1
    }
    if (obj[kbpsKey] !== undefined) {
      var k = Number(obj[kbpsKey])
      return isFinite(k) ? Math.max(0, k * 1024) : -1
    }
    return -1
  }

  function numArr(v, cap) {
    if (!Array.isArray(v))
      return []
    var out = []
    for (var i = 0; i < v.length && out.length < cap; i++) {
      var n = Number(v[i])
      if (isFinite(n))
        out.push(n)
    }
    return out
  }

  // Filled sparkline. `domain` > 0 pins the top of the scale (percentages,
  // °C); domain 0 auto-scales to the largest sample — used for
  // history.mem_used whose unit is collector-defined (MB today).
  function paintSparkline(ctx, w, h, values, color, domain) {
    ctx.clearRect(0, 0, w, h)
    if (!values || values.length < 2 || w <= 0 || h <= 0)
      return
    var max = domain > 0 ? domain : 0
    for (var i = 0; i < values.length; i++) {
      var n = Number(values[i])
      if (isFinite(n) && n > max)
        max = n
    }
    if (max <= 0)
      max = 1
    var stepX = w / (values.length - 1)
    var pts = []
    for (i = 0; i < values.length; i++) {
      var v = Number(values[i])
      if (!isFinite(v) || v < 0)
        v = 0
      pts.push(h - Math.min(v, max) / max * h)
    }
    ctx.beginPath()
    ctx.moveTo(0, h)
    for (i = 0; i < pts.length; i++)
      ctx.lineTo(i * stepX, pts[i])
    ctx.lineTo(w, h)
    ctx.closePath()
    ctx.fillStyle = Util.alpha(color, 0.18)
    ctx.fill()
    ctx.beginPath()
    ctx.moveTo(0, pts[0])
    for (i = 1; i < pts.length; i++)
      ctx.lineTo(i * stepX, pts[i])
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.stroke()
  }

  // Small header chevron that toggles a card's drill-down section.
  component DrillChevron: Rectangle {
    id: chevRoot
    property bool expanded: false
    signal toggled()
    implicitWidth: Style.space(18)
    implicitHeight: Style.space(18)
    radius: Style.space(4)
    color: chevMa.containsMouse ? Util.alpha(root.fg, 0.12) : "transparent"
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chevRoot.expanded ? "▾" : "▸"
      color: root.muted
      font.pixelSize: Style.font.bodySmall
    }
    MouseArea {
      id: chevMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chevRoot.toggled()
    }
  }

  // Compact drill-down proc row: clean alias + right-side metric + kill.
  // Apps (app-/session-scoped) die on one click; services and unclassifiable
  // procs arm the shared "Kill …?" confirm — same armedPid the main list uses.
  component DrillProcRow: Rectangle {
    id: drillRow
    required property var proc
    property string metric: ""
    readonly property bool armed: proc && parseInt(proc.pid) === root.armedPid
    implicitWidth: parent ? parent.width : 0
    height: Style.space(22)
    radius: Style.space(4)
    clip: true
    color: armed ? Util.alpha(root.urgent, 0.22) : "transparent"
    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)
      Rectangle {
        visible: !drillRow.armed
        implicitWidth: Style.space(6)
        implicitHeight: Style.space(6)
        radius: Style.space(3)
        color: root.killTier(drillRow.proc) === "service" ? root.urgent : root.muted
      }
      Text {
        visible: !drillRow.armed
        textFormat: Text.PlainText
        text: drillRow.proc ? (drillRow.proc.display || drillRow.proc.name || "unknown") : ""
        color: root.fg
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
      Text {
        visible: !drillRow.armed && drillRow.metric.length > 0
        textFormat: Text.PlainText
        text: drillRow.metric
        color: root.muted
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
      }
      Text {
        visible: drillRow.armed
        textFormat: Text.PlainText
        text: "Kill " + (drillRow.proc ? (drillRow.proc.display || drillRow.proc.name || "?") : "?")
              + " · " + (drillRow.proc ? (drillRow.proc.comm || drillRow.proc.name || "?") : "?")
              + " · pid " + (drillRow.proc ? drillRow.proc.pid : "?") + "?"
        color: root.urgent
        font.bold: true
        font.pixelSize: Style.font.caption
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
      Rectangle {
        implicitWidth: Style.space(16)
        implicitHeight: Style.space(16)
        radius: Style.space(4)
        color: root.urgent
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: drillRow.armed ? "?" : "x"
          color: Color.background
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!drillRow.proc)
              return
            if (root.killTier(drillRow.proc) === "app")
              root.killProcess(parseInt(drillRow.proc.pid))
            else
              root.armKill(drillRow.proc)
          }
        }
      }
    }
  }

  // Non-process drill row (per-iface / per-disk rates): label + metric only.
  component DrillTextRow: Rectangle {
    id: drillTextRow
    property string label: ""
    property string metric: ""
    implicitWidth: parent ? parent.width : 0
    height: Style.space(20)
    radius: Style.space(4)
    clip: true
    color: "transparent"
    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)
      Text {
        textFormat: Text.PlainText
        text: drillTextRow.label
        color: root.fg
        font.pixelSize: Style.font.caption
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
      Text {
        visible: drillTextRow.metric.length > 0
        textFormat: Text.PlainText
        text: drillTextRow.metric
        color: root.muted
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
      }
    }
  }

  // Cap + normalize collector-provided strings before they reach Text sinks:
  // process names and mount paths are locally controlled and must never carry
  // markup or runaway length into the persistent shell.
  function clipStr(v, n) {
    return String(v == null ? "" : v).replace(/[\x00-\x1f\x7f-\x9f<>]/g, " ").slice(0, n || 80)
  }

  // Drop the hover identity tip: the row it anchored to may be rebuilt or
  // re-sorted on every stats pass, so a stale anchor must never linger.
  function dropProcHover() {
    procTipTimer.stop()
    procTip.visible = false
    root.hoverProcData = null
    root.hoverProcRow = null
  }

  // Position + show the identity tip inside the processes card (KTD3):
  // right-edge aware, flips above the row when the space below is short, and
  // the card's own clip guarantees it can never paint outside the panel.
  function showProcTip() {
    if (!root.hoverProcRow || !root.hoverProcData)
      return
    var p = root.hoverProcRow.mapToItem(procCard, 0, 0)
    var pad = Style.space(6)
    var w = procTip.width
    var h = procTip.height
    var x = p.x + Style.space(20)
    x = Math.max(pad, Math.min(x, procCard.width - w - pad))
    var yBelow = p.y + root.hoverProcRow.height + pad
    var y = (yBelow + h + pad <= procCard.height) ? yBelow : Math.max(pad, p.y - h - pad)
    procTip.x = Math.round(x)
    procTip.y = Math.round(y)
    procTip.visible = true
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
              c.display = clipStr(c.display || c.name, 48)
              c.unit = clipStr(c.unit, 64)
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
              p.display = clipStr(p.display || p.name, 48)
              p.comm = clipStr(p.comm || p.name, 48)
              p.exe = clipStr(p.exe, 96)
              p.exe_path = clipStr(p.exe_path, 120)
              p.args = clipStr(p.args, 160)
              p.unit = clipStr(p.unit, 64)
              return p
            })
          if (Array.isArray(data.top_cpu))
            root.topCpu = data.top_cpu.slice(0, 32).map(function(p) {
              p.name = clipStr(p.name, 48)
              p.display = clipStr(p.display || p.name, 48)
              p.comm = clipStr(p.comm || p.name, 48)
              p.unit = clipStr(p.unit, 64)
              return p
            })
          if (Array.isArray(data.disks))
            root.disks = data.disks.slice(0, 24).map(function(d) {
              d.mount = clipStr(d.mount, 64)
              return d
            })
          if (Array.isArray(data.fan_curve))
            root.fanCurve = data.fan_curve
          // Additive keys (KTD6): byte/sec deltas and history rings arrive
          // only once the collector has a previous sample — absent keys leave
          // the sentinels at -1/[] and the matching surfaces stay hidden.
          root.netDownBps = bpsField(data.net, "down_bps", "rx_kbps")
          root.netUpBps = bpsField(data.net, "up_bps", "tx_kbps")
          root.diskReadBps = bpsField(data.disk, "read_bps", "read_kbps")
          root.diskWriteBps = bpsField(data.disk, "write_bps", "write_kbps")
          var netD = data.net && typeof data.net === "object" ? data.net : null
          root.netIfaces = (netD && Array.isArray(netD.ifaces))
            ? netD.ifaces.slice(0, 12).map(function(i) {
                i.name = clipStr(i.name, 24)
                return i
              }) : []
          var diskD = data.disk && typeof data.disk === "object" ? data.disk : null
          root.diskDevs = (diskD && Array.isArray(diskD.devs))
            ? diskD.devs.slice(0, 12).map(function(i) {
                i.name = clipStr(i.name, 24)
                return i
              }) : []
          var hist = data.history && typeof data.history === "object" ? data.history : null
          root.histCpu = hist ? numArr(hist.cpu_load, 120) : []
          root.histTemp = hist ? numArr(hist.cpu_temp, 120) : []
          root.histMem = hist ? numArr(hist.mem_used, 120) : []
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

  // Rows shown in the process list: live find results while searching,
  // otherwise the top-memory slice from the regular stats pass.
  readonly property var procList: (root.procFilter.length > 0 ? root.findResults : root.topMem) || []

  onProcFilterChanged: {
    // A filter edit also drops any pending kill arm: the armed row may be
    // filtered out, and an invisible confirm must never complete (KTD4).
    root.disarmKill()
    root.dropProcHover()
    root.selectedProc = 0
    if (root.procFilter.length > 0)
      findDebounce.restart()
    else
      root.findResults = []
  }

  // Row rebuilds on every pass invalidate the tip's anchor item.
  onTopMemChanged: root.dropProcHover()
  onFindResultsChanged: root.dropProcHover()

  // Closing the panel drops transient interaction state — an arm that
  // outlives a close/reopen would read as a surprise pending kill.
  onOpenedChanged: {
    if (!root.opened) {
      root.dropProcHover()
      root.disarmKill()
    }
  }

  Timer {
    id: findDebounce
    interval: 250
    onTriggered: {
      if (root.procFilter.length > 0 && !findProc.running && root.procFilter !== root.findInFlight) {
        root.findInFlight = root.procFilter
        findProc.running = true
      }
    }
  }

  // Armed-kill window: the row stays in its confirm state for 3 s, then
  // reverts without sending anything (KTD4).
  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.disarmKill()
  }

  // Hover delay for the identity tip — long enough that a pointer crossing
  // rows on the way to the × button doesn't flicker tooltips (KTD3).
  Timer {
    id: procTipTimer
    interval: 350
    onTriggered: root.showProcTip()
  }

  Process {
    id: findProc
    command: [root.py, root.pluginRoot + "/bin/system_monitor_stats.py", "--find", root.procFilter]
    clearEnvironment: true
    environment: root.procEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (Array.isArray(data.procs))
            root.findResults = data.procs.slice(0, 32).map(function(p) {
              p.name = clipStr(p.name, 48)
              p.display = clipStr(p.display || p.name, 48)
              p.comm = clipStr(p.comm || p.name, 48)
              p.exe = clipStr(p.exe, 96)
              p.exe_path = clipStr(p.exe_path, 120)
              p.args = clipStr(p.args, 160)
              p.unit = clipStr(p.unit, 64)
              return p
            })
        } catch (e) {
          root.findResults = []
        }
      }
    }
    onExited: function (code) {
      // Re-fire only if the filter moved on while this pass was in flight.
      if (root.procFilter.length > 0 && root.procFilter !== root.findInFlight)
        findDebounce.restart()
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
    text: "󰍛 " + root.memUsed + "G " + root.cpuTemp
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
      if (root.findMode) {
        if (event.key === Qt.Key_Escape) {
          root.findMode = false
          root.procFilter = ""
          root.disarmKill()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.findMode = false
          event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
          root.procFilter = root.procFilter.slice(0, -1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
          root.selectedProc = Math.min(root.procList.length - 1, root.selectedProc + 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
          root.selectedProc = Math.max(0, root.selectedProc - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_X && (event.modifiers & Qt.ControlModifier) && root.procList[root.selectedProc]) {
          root.armKill(root.procList[root.selectedProc])
          event.accepted = true
        } else if (event.text && event.text.length === 1) {
          // In find mode every printable char types into the filter —
          // including 'x' (kill stays available via Ctrl+X or the row button).
          root.procFilter += event.text
          event.accepted = true
        }
        return
      }
      if (event.key === Qt.Key_Slash) {
        root.findMode = true
        event.accepted = true
      } else if (event.key === Qt.Key_J) {
        root.selectedProc = Math.min(root.procList.length - 1, root.selectedProc + 1)
        event.accepted = true
      } else if (event.key === Qt.Key_K) {
        root.selectedProc = Math.max(0, root.selectedProc - 1)
        event.accepted = true
      } else if (event.key === Qt.Key_X && root.procList[root.selectedProc]) {
        root.armKill(root.procList[root.selectedProc])
        event.accepted = true
      } else if (event.key === Qt.Key_B) {
        root.btop()
        event.accepted = true
      } else if (event.key === Qt.Key_Escape && (root.procFilter.length > 0 || root.armedPid > 0)) {
        // Clears the filter first, then disarms — one Esc handles both.
        root.procFilter = ""
        root.disarmKill()
        event.accepted = true
      }
    }

    // The card stack can exceed the panel's 720px cap — wrap it in a
    // Flickable so expanded drill-downs scroll instead of pushing the fan
    // controls and process list below the fold.
    Flickable {
      id: scrollView
      anchors.fill: parent
      contentWidth: width
      contentHeight: mainColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: mainColumn
        width: scrollView.width
        spacing: Style.space(8)

      // Panel header (outside the cards): title, fetch error, mode badge.
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
          implicitWidth: modeLabel.implicitWidth + 14
          implicitHeight: 22
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

      // ------------------------------------------------------ Memory card
      Rectangle {
        width: parent.width
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: memCard.implicitHeight + Style.space(24)
        Column {
          id: memCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: "MEMORY"
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Item {
              Layout.fillWidth: true
            }
            Text {
              text: root.memPct + "% used"
              textFormat: Text.PlainText
              color: root.memColor()
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            DrillChevron {
              expanded: root.openMem
              onToggled: root.openMem = !root.openMem
            }
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: root.memUsed
              textFormat: Text.PlainText
              color: root.memColor()
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }
            Text {
              text: "GB"
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              Layout.alignment: Qt.AlignBottom
              Layout.bottomMargin: Style.space(4)
            }
            Text {
              text: "of " + root.memTotal + " GB"
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.bodySmall
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignBottom
              Layout.bottomMargin: Style.space(4)
              elide: Text.ElideRight
            }
          }
          Rectangle {
            width: parent.width
            height: Style.space(8)
            radius: Style.space(4)
            color: Util.alpha(root.fg, 0.15)
            Rectangle {
              width: Math.max(4, parent.width * (root.memPct / 100.0))
              height: parent.height
              radius: parent.radius
              color: root.memColor()
            }
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "avail " + root.memAvail + "G · swap " + root.swapUsed + "/" + root.swapTotal + "G" + (root.ramInfo ? " · " + root.ramInfo : "")
            color: root.muted
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Canvas {
            id: memSpark
            visible: root.histMem.length > 1
            width: parent.width
            height: Style.space(36)
            onPaint: root.paintSparkline(getContext("2d"), width, height, root.histMem, root.memColor(), 0)
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            Connections {
              target: root
              function onHistMemChanged() { if (memSpark.visible) memSpark.requestPaint() }
            }
          }
          // Drill-down: biggest RSS consumers; x kills apps, ? arms services.
          Column {
            visible: root.openMem && root.topMem.length > 0
            width: parent.width
            spacing: Style.space(2)
            Repeater {
              model: root.openMem ? root.topMem.slice(0, 6) : []
              delegate: DrillProcRow {
                required property var modelData
                proc: modelData
                metric: root.procMemText(modelData)
              }
            }
          }
        }
      }

      // --------------------------------------------------------- CPU card
      Rectangle {
        width: parent.width
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: cpuCard.implicitHeight + Style.space(24)
        Column {
          id: cpuCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: "CPU"
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Item {
              Layout.fillWidth: true
            }
            Text {
              text: root.cpuName
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.caption
              Layout.maximumWidth: Style.space(220)
              elide: Text.ElideRight
            }
            DrillChevron {
              expanded: root.openCpu
              onToggled: root.openCpu = !root.openCpu
            }
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: root.cpuLoad
              textFormat: Text.PlainText
              color: root.levelColor(root.cpuLoad, 70, 90)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }
            Text {
              text: "%"
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              Layout.alignment: Qt.AlignBottom
              Layout.bottomMargin: Style.space(4)
            }
            Item {
              Layout.fillWidth: true
            }
          }
          Rectangle {
            width: parent.width
            height: Style.space(8)
            radius: Style.space(4)
            color: Util.alpha(root.fg, 0.15)
            Rectangle {
              width: Math.max(4, parent.width * (root.cpuLoad / 100.0))
              height: parent.height
              radius: parent.radius
              color: root.levelColor(root.cpuLoad, 70, 90)
            }
          }
          Canvas {
            id: cpuSpark
            visible: root.histCpu.length > 1
            width: parent.width
            height: Style.space(36)
            onPaint: root.paintSparkline(getContext("2d"), width, height, root.histCpu, root.levelColor(root.cpuLoad, 70, 90), 100)
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            Connections {
              target: root
              function onHistCpuChanged() { if (cpuSpark.visible) cpuSpark.requestPaint() }
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
              font.pixelSize: Style.font.caption
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
                  width: (coresGrid.width - coresGrid.columnSpacing * (coresGrid.columns - 1)) / coresGrid.columns
                  height: Style.space(20)
                  radius: Style.space(3)
                  color: "transparent"
                  border.color: Util.alpha(root.fg, 0.4)
                  border.width: 1
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
          // Drill-down: top CPU consumers; x kills apps, ? arms services.
          Column {
            visible: root.openCpu && root.topCpu.length > 0
            width: parent.width
            spacing: Style.space(2)
            Repeater {
              model: root.openCpu ? root.topCpu.slice(0, 6) : []
              delegate: DrillProcRow {
                required property var modelData
                proc: modelData
                metric: {
                  var c = root.procCpu(modelData)
                  return c >= 0 ? Math.round(c) + "%" : "--"
                }
              }
            }
          }
        }
      }

      // ---------------------------------------------------- Thermals card
      Rectangle {
        width: parent.width
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: thermCard.implicitHeight + Style.space(24)
        Column {
          id: thermCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "THERMALS"
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(20)
            Column {
              spacing: Style.space(2)
              Text {
                text: "CPU"
                textFormat: Text.PlainText
                color: root.muted
                font.pixelSize: Style.font.caption
              }
              Text {
                text: root.cpuTemp
                textFormat: Text.PlainText
                color: root.tempColor(root.cpuTemp)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }
            Column {
              spacing: Style.space(2)
              Text {
                text: "GPU"
                textFormat: Text.PlainText
                color: root.muted
                font.pixelSize: Style.font.caption
              }
              Text {
                text: root.gpuTemp
                textFormat: Text.PlainText
                color: root.tempColor(root.gpuTemp)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }
            Column {
              spacing: Style.space(2)
              Text {
                text: "NVMe"
                textFormat: Text.PlainText
                color: root.muted
                font.pixelSize: Style.font.caption
              }
              Text {
                text: root.nvmeTemp
                textFormat: Text.PlainText
                color: root.tempColor(root.nvmeTemp)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }
            Item {
              Layout.fillWidth: true
            }
          }
          Canvas {
            id: tempSpark
            visible: root.histTemp.length > 1
            width: parent.width
            height: Style.space(36)
            onPaint: root.paintSparkline(getContext("2d"), width, height, root.histTemp, root.tempColor(root.cpuTemp), 100)
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            Connections {
              target: root
              function onHistTempChanged() { if (tempSpark.visible) tempSpark.requestPaint() }
            }
          }
        }
      }

      // --------------------------------------------------------- GPU card
      Rectangle {
        width: parent.width
        visible: root.gpuName !== "GPU" || root.gpuLoad >= 0 || root.gpuTemp !== "--" || root.gpuLoadReason !== ""
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: gpuCard.implicitHeight + Style.space(24)
        Column {
          id: gpuCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: "GPU"
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Item {
              Layout.fillWidth: true
            }
            Text {
              text: root.gpuName
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.caption
              Layout.maximumWidth: Style.space(220)
              elide: Text.ElideRight
            }
            DrillChevron {
              visible: root.gpuClients.length > 0
              expanded: root.openGpu
              onToggled: root.openGpu = !root.openGpu
            }
          }
          Text {
            visible: root.gpuLoad >= 0
            text: root.gpuLoad >= 0 ? root.gpuLoad + "%" : "--"
            textFormat: Text.PlainText
            color: root.levelColor(root.gpuLoad, 70, 90)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
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
            height: Style.space(8)
            radius: Style.space(4)
            color: Util.alpha(root.fg, 0.15)
            Rectangle {
              width: Math.max(4, parent.width * (root.gpuLoad / 100.0))
              height: parent.height
              radius: parent.radius
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
          // Drill-down: procs holding /dev/dri fds (fd-holders, not measured
          // load) — x kills apps, ? arms services, same tiers as other cards.
          Column {
            visible: root.openGpu && root.gpuClients.length > 0
            width: parent.width
            spacing: Style.space(2)
            Repeater {
              model: root.openGpu ? root.gpuClients.slice(0, 8) : []
              delegate: DrillProcRow {
                required property var modelData
                proc: modelData
                metric: "pid " + modelData.pid
              }
            }
            Text {
              visible: root.gpuClients.length > 8
              textFormat: Text.PlainText
              text: "… +" + (root.gpuClients.length - 8) + " more"
              color: root.muted
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ------------------------------------- Net/disk rate mini-cards (R6)
      // Each renders only when the collector emitted its keys; the row itself
      // disappears when neither exists, so an older collector shows nothing.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        visible: root.netDownBps >= 0 || root.netUpBps >= 0 || root.diskReadBps >= 0 || root.diskWriteBps >= 0
        Rectangle {
          visible: root.netDownBps >= 0 || root.netUpBps >= 0
          Layout.fillWidth: true
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.fg, Color.accent)
          border.color: Util.alpha(root.fg, 0.08)
          border.width: 1
          implicitHeight: netCard.implicitHeight + Style.space(20)
          Column {
            id: netCard
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(4)
            RowLayout {
              width: parent.width
              PanelSectionHeader {
                text: "NETWORK"
                foreground: root.fg
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              }
              Item {
                Layout.fillWidth: true
              }
              DrillChevron {
                visible: root.netIfaces.length > 0
                expanded: root.openNet
                onToggled: root.openNet = !root.openNet
              }
            }
            Text {
              textFormat: Text.PlainText
              text: "↓ " + root.fmtRate(root.netDownBps)
              color: root.fg
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: "↑ " + root.fmtRate(root.netUpBps)
              color: root.muted
              font.pixelSize: Style.font.bodySmall
            }
            // Drill-down: per-interface rates (no kill — nothing to kill).
            Column {
              visible: root.openNet && root.netIfaces.length > 0
              width: parent.width
              spacing: Style.space(1)
              Repeater {
                model: root.openNet ? root.netIfaces : []
                delegate: DrillTextRow {
                  required property var modelData
                  label: modelData.name
                  metric: "↓" + root.fmtRate(modelData.down_bps) + " ↑" + root.fmtRate(modelData.up_bps)
                }
              }
            }
          }
        }
        Rectangle {
          visible: root.diskReadBps >= 0 || root.diskWriteBps >= 0
          Layout.fillWidth: true
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.fg, Color.accent)
          border.color: Util.alpha(root.fg, 0.08)
          border.width: 1
          implicitHeight: diskCard.implicitHeight + Style.space(20)
          Column {
            id: diskCard
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(4)
            RowLayout {
              width: parent.width
              PanelSectionHeader {
                text: "DISK I/O"
                foreground: root.fg
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              }
              Item {
                Layout.fillWidth: true
              }
              DrillChevron {
                visible: root.diskDevs.length > 0
                expanded: root.openDisk
                onToggled: root.openDisk = !root.openDisk
              }
            }
            Text {
              textFormat: Text.PlainText
              text: "R " + root.fmtRate(root.diskReadBps)
              color: root.fg
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: "W " + root.fmtRate(root.diskWriteBps)
              color: root.muted
              font.pixelSize: Style.font.bodySmall
            }
            // Drill-down: per-device rates.
            Column {
              visible: root.openDisk && root.diskDevs.length > 0
              width: parent.width
              spacing: Style.space(1)
              Repeater {
                model: root.openDisk ? root.diskDevs : []
                delegate: DrillTextRow {
                  required property var modelData
                  label: modelData.name
                  metric: "R " + root.fmtRate(modelData.read_bps) + " W " + root.fmtRate(modelData.write_bps)
                }
              }
            }
          }
        }
      }

      // ----------------------------------------------------- Storage card
      Rectangle {
        width: parent.width
        visible: root.disks.length > 0
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: diskListCard.implicitHeight + Style.space(24)
        Column {
          id: diskListCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(6)
          PanelSectionHeader {
            text: "STORAGE"
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }
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
                color: Util.alpha(root.fg, 0.15)
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

      // --------------------------------------------------------- Fan card
      Rectangle {
        width: parent.width
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        implicitHeight: fanCard.implicitHeight + Style.space(24)
        Column {
          id: fanCard
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: "FAN"
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Item {
              Layout.fillWidth: true
            }
          }
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: root.fan1Rpm + (root.fan2Rpm > 0 ? " / " + root.fan2Rpm : "")
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }
            Text {
              text: "RPM"
              textFormat: Text.PlainText
              color: root.muted
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              Layout.alignment: Qt.AlignBottom
              Layout.bottomMargin: Style.space(4)
            }
            Item {
              Layout.fillWidth: true
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

              ctx.strokeStyle = Util.alpha(root.fg, 0.15)
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
      }

      // ---------------------------------------------------- Processes card
      Rectangle {
        id: procCard
        width: parent.width
        visible: root.procList.length > 0 || root.findMode || root.procFilter.length > 0
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.fg, Color.accent)
        border.color: Util.alpha(root.fg, 0.08)
        border.width: 1
        // The identity tip lives inside this clip: it can never paint past
        // the card edge (plan risk: tooltip vs. panel clipping).
        clip: true
        implicitHeight: procCol.implicitHeight + Style.space(24)
        Column {
          id: procCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(6)
          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: root.procFilter.length > 0 ? "PROCESSES · filtered" : "PROCESSES · top memory"
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Item {
              Layout.fillWidth: true
            }
            Text {
              textFormat: Text.PlainText
              text: "j/k · / find · x kill · b btop"
              color: root.muted
              font.pixelSize: Style.font.caption
            }
          }
          Rectangle {
            visible: root.findMode || root.procFilter.length > 0
            width: parent.width
            height: Style.space(24)
            radius: Style.space(4)
            color: root.findMode ? root.surface : "transparent"
            border.color: root.findMode ? root.accent : root.fg
            border.width: root.findMode ? 1 : 0
            clip: true
            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(6)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "/ " + root.procFilter + (root.findMode ? "▌" : "")
                color: root.fg
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: !root.findMode
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "· esc clear · / edit"
                color: root.muted
                font.pixelSize: Style.font.caption
              }
            }
          }
          Repeater {
            model: root.procList
            delegate: Rectangle {
              id: procRow
              required property var modelData
              required property int index
              // Armed state is keyed by pid, not index: a refresh re-sort can
              // never shift the confirm onto a different process (KTD4).
              readonly property bool armed: parseInt(modelData.pid) === root.armedPid
              readonly property real cpuVal: root.procCpu(modelData)
              width: parent ? parent.width : 0
              height: Style.space(26)
              radius: Style.space(4)
              clip: true
              color: armed ? Util.alpha(root.urgent, 0.22)
                     : (index === root.selectedProc ? Style.selectedFillFor(root.fg, Color.accent) : "transparent")
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selectedProc = index
              }
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)
                Rectangle {
                  visible: !procRow.armed
                  implicitWidth: Style.space(8)
                  implicitHeight: Style.space(8)
                  radius: Style.space(4)
                  color: procRow.cpuVal >= 50 ? root.urgent
                         : root.dotPalette[index % root.dotPalette.length]
                }
                Text {
                  id: aliasText
                  visible: !procRow.armed
                  text: modelData.display || modelData.name || "unknown"
                  textFormat: Text.PlainText
                  color: root.fg
                  font.bold: true
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                  Layout.minimumWidth: 60
                  elide: Text.ElideRight
                  // Name-area hover → delayed identity overlay (KTD3). This
                  // MouseArea sits above the row's own, so it also selects.
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: {
                      root.selectedProc = index
                      root.hoverProcData = modelData
                      root.hoverProcRow = procRow
                      procTipTimer.restart()
                    }
                    onExited: {
                      procTipTimer.stop()
                      procTip.visible = false
                      root.hoverProcData = null
                      root.hoverProcRow = null
                    }
                  }
                }
                Text {
                  visible: !procRow.armed
                  textFormat: Text.PlainText
                  text: procRow.cpuVal >= 0 ? Math.round(procRow.cpuVal) + "%" : "--"
                  color: procRow.cpuVal >= 50 ? root.urgent : root.muted
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(34)
                  horizontalAlignment: Text.AlignRight
                }
                Text {
                  visible: !procRow.armed
                  text: root.procMemText(modelData)
                  textFormat: Text.PlainText
                  color: root.fg
                  font.pixelSize: Style.font.bodySmall
                  Layout.preferredWidth: Style.space(64)
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                }
                Text {
                  // In-row armed confirm — names the exact target: friendly
                  // alias, raw comm, and pid (KTD4: no hidden footgun).
                  visible: procRow.armed
                  textFormat: Text.PlainText
                  text: "Kill " + (modelData.display || modelData.name || "?")
                        + " · " + (modelData.comm || modelData.name || "?")
                        + " · pid " + modelData.pid + "?"
                  color: root.urgent
                  font.bold: true
                  font.pixelSize: Style.font.bodySmall
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Rectangle {
                  implicitWidth: Style.space(18)
                  implicitHeight: Style.space(18)
                  radius: Style.space(4)
                  color: root.urgent
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: procRow.armed ? "?" : "x"
                    color: Color.background
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.armKill(modelData)
                  }
                }
              }
            }
          }
        }
        // Identity tip (KTD3): delayed hover overlay anchored inside this
        // card — shows the technical identity the alias-only row hides.
        Rectangle {
          id: procTip
          visible: false
          z: 10
          radius: Style.cornerRadius
          color: Color.tooltip.background
          border.color: Color.tooltip.border
          border.width: 1
          width: Math.min(Style.space(300), Math.max(Style.space(160), procCard.width - Style.space(24)))
          implicitHeight: tipCol.implicitHeight + Style.space(16)
          Column {
            id: tipCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            spacing: Style.space(3)
            Text {
              text: root.hoverProcData ? (root.hoverProcData.display || root.hoverProcData.name || "unknown") : ""
              textFormat: Text.PlainText
              color: Color.tooltip.text
              font.bold: true
              font.pixelSize: Style.font.bodySmall
              width: parent.width
              elide: Text.ElideRight
            }
            Text {
              text: root.hoverProcData
                    ? (root.clipStr(root.hoverProcData.comm || root.hoverProcData.name || "?", 48)
                       + " · pid " + root.hoverProcData.pid
                       + " · rss " + root.procMemText(root.hoverProcData)
                       + (root.hoverProcData.cpu !== undefined || root.hoverProcData.cpu_pct !== undefined
                          ? " · cpu " + Math.round(root.procCpu(root.hoverProcData)) + "%" : "")
                       + (root.hoverProcData.unit ? " · " + root.clipStr(root.hoverProcData.unit, 40) : ""))
                    : ""
              textFormat: Text.PlainText
              color: Color.tooltip.text
              font.pixelSize: Style.font.caption
              width: parent.width
              elide: Text.ElideRight
            }
            Text {
              visible: !!(root.hoverProcData && (root.hoverProcData.exe_path || root.hoverProcData.exe))
              text: root.hoverProcData ? (root.hoverProcData.exe_path || root.hoverProcData.exe) : ""
              textFormat: Text.PlainText
              color: Color.tooltip.text
              font.pixelSize: Style.font.caption
              width: parent.width
              elide: Text.ElideRight
            }
            Text {
              visible: !!(root.hoverProcData && root.hoverProcData.args)
              text: root.hoverProcData ? root.hoverProcData.args : ""
              textFormat: Text.PlainText
              color: Color.tooltip.text
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
          }
        }
      }
    }
    }
  }
}

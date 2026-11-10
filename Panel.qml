import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Data owner and details panel for io.github.manish0467.thermal-power.
//
// The Python helper collects read-only sysfs facts every 10 s while the panel
// is closed and every 2 s while it is open. UPower, PowerProfiles and a single
// busctl read supply the values Linux does not expose to an unprivileged user.
// All history and notification cooldowns are in memory; this plugin has no
// state directory of its own.
Panel {
  id: root
  moduleName: "io.github.manish0467.thermal-power"
  ipcTarget: "io.github.manish0467.thermal-power"

  // Injected by BarWidget.injectPanel().
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---------------------------------------------------------------- settings
  readonly property var cfg: Model.sanitizeConfig({
    warmThreshold: setting("warmThreshold", 80),
    hotThreshold: setting("hotThreshold", 90),
    unit: setting("unit", "c"),
    barFields: setting("barFields", ["temp", "power"]),
    pollClosedSeconds: setting("pollClosedSeconds", 10),
    pollOpenSeconds: setting("pollOpenSeconds", 2),
    historyMinutes: setting("historyMinutes", 5),
    notifyTemp: setting("notifyTemp", false),
    notifyTempC: setting("notifyTempC", 92),
    notifyTempSeconds: setting("notifyTempSeconds", 90),
    notifyPower: setting("notifyPower", false),
    notifyPowerW: setting("notifyPowerW", 30),
    notifyPowerSeconds: setting("notifyPowerSeconds", 60),
    notifyCooldownMinutes: setting("notifyCooldownMinutes", 15)
  })
  readonly property string unit: cfg.unit
  readonly property int warmC: cfg.warmC
  readonly property int hotC: cfg.hotC

  readonly property string mockRaw: String(setting("mockScenario", "")).trim()
  readonly property string mockName: /^[a-z0-9][a-z0-9-]*$/.test(mockRaw) ? mockRaw : ""
  readonly property string mockError: mockRaw !== "" && mockName === "" ? "Invalid preview fixture name" : ""
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("helper/thermal_power.py")).replace(/^file:\/\//, ""))

  // ------------------------------------------------------------------- data
  function emptyDocument() {
    return {
      schema: 1, generated_at: 0, mock: null,
      cpu: { available: false, package_c: null, package_label: "", package_source: "", crit_c: null, cores: [], sensors: [], max_c: null },
      fans: [], cooling: { available: false, active: false, devices: [], other_count: 0 },
      throttle: { supported: false, cpu_count: 0, core_count: 0, package_count: 0, core_total_ms: 0, package_total_ms: 0, core_max_ms: 0, package_max_ms: 0 },
      freq: { available: false, policy_count: 0, driver: "", governor: "", epp: "", cur_min_mhz: null, cur_max_mhz: null, scaling_max_mhz: null, cap_mhz: null, cpuinfo_max_mhz: null, capped: false, boost: null },
      pstate: { kind: "", status: "", no_turbo: null, turbo_pct: null, max_perf_pct: null, min_perf_pct: null, hwp_dynamic_boost: null },
      power_limits: [],
      battery: emptyBattery(),
      warnings: []
    }
  }

  function emptyBattery() {
    return {
      present: false, name: "", count: 0, status: "", percent: null,
      energy_wh: null, energy_full_wh: null, charge_ah: null,
      charge_full_ah: null, voltage_v: null, cycle_count: null,
      power_w: null, power_source: "", power_direction: "",
      ac_online: false, ac_known: false, ac_name: "", time_minutes: null
    }
  }

  property var doc: emptyDocument()
  property bool gotDoc: false
  property bool helperRunning: false
  property bool startupDone: false
  property bool refreshing: false
  property string runError: ""
  property string helperStderr: ""
  property int helperExitCode: 0
  property double lastUpdateMs: 0
  property double nowMs: Date.now()

  property var battery: emptyBattery()
  property var history: []
  property var emaState: ({})
  property var notifState: ({})
  property var notifQueue: []
  property var mockAux: null
  property string mockSeeded: ""
  property string lastMockRaw: ""
  property bool showOtherSensors: false
  property bool showThrottleNotes: false

  property var throttlePrev: null
  property double lastThrottleAt: 0
  property double lastMockEventAt: 0
  property var throttleEvents: []

  property var realProfiles: []
  property string nativeProfile: ""
  property bool managerProbeDone: false
  property bool managerProbeRunning: false
  property bool ppdActive: false
  property string powerManager: ""
  property bool profileProbeDone: false
  property bool profileProbeRunning: false
  property string profileError: ""
  property bool switching: false
  property string pendingProfile: ""
  property string switchError: ""

  readonly property bool hasTemp: runError === "" && doc && doc.cpu && Model.isFiniteNumber(doc.cpu.package_c)
  readonly property real packageC: hasTemp ? doc.cpu.package_c : NaN
  readonly property real critC: doc && doc.cpu && Model.isFiniteNumber(doc.cpu.crit_c) ? doc.cpu.crit_c : NaN
  readonly property var cores: doc && doc.cpu && Array.isArray(doc.cpu.cores) ? doc.cpu.cores : []
  readonly property var sensors: doc && doc.cpu && Array.isArray(doc.cpu.sensors) ? doc.cpu.sensors : []
  readonly property var fans: doc && Array.isArray(doc.fans) ? doc.fans : []
  readonly property var powerLimits: doc && Array.isArray(doc.power_limits) ? doc.power_limits : []
  readonly property var warnings: doc && Array.isArray(doc.warnings) ? doc.warnings : []
  readonly property bool coolingActive: doc && doc.cooling ? doc.cooling.active === true : false
  readonly property bool throttleActive: coolingActive || (lastThrottleAt > 0 && nowMs - lastThrottleAt < 15000)
  readonly property real throttleAgeSeconds: lastThrottleAt > 0 ? Math.max(0, (nowMs - lastThrottleAt) / 1000) : -1

  readonly property string overall: runError !== "" ? "unavailable" : Model.classifyState({
    tempC: hasTemp ? packageC : null,
    throttleActive: throttleActive,
    warmC: warmC,
    hotC: hotC
  })

  readonly property string unavailableReason: {
    if (runError !== "") return "Collector error"
    if (!gotDoc) return "Starting"
    if (!hasTemp) return "No CPU temperature sensor"
    return ""
  }

  readonly property color stateColor: {
    if (overall === "hot" || overall === "throttling") return Commons.Color.urgent
    if (overall === "warm") return Qt.rgba(0.88, 0.62, 0.14, 1)
    if (overall === "unavailable") return Commons.Color.muted
    return root.barForeground
  }

  readonly property string barLabel: Model.buildBarLabel({
    tempC: hasTemp && runError === "" ? packageC : null,
    unit: unit,
    battery: battery,
    profile: activeProfile,
    fields: cfg.barFields
  })

  function stateText(value) {
    if (value === "normal") return "Normal"
    if (value === "warm") return "Warm"
    if (value === "hot") return "Hot"
    if (value === "throttling") return "Throttling evidence"
    return "Unavailable"
  }

  function profileSource() {
    if (mockAux && mockAux.profile) return mockAux.profile
    return null
  }

  readonly property var activeProfile: {
    var mockProfile = profileSource()
    if (mockProfile) return String(mockProfile.active || "")
    return nativeProfile
  }

  readonly property var profiles: {
    var mockProfile = profileSource()
    if (mockProfile) return Array.isArray(mockProfile.profiles) ? mockProfile.profiles.slice() : []
    return realProfiles
  }

  readonly property string readonlyReason: {
    var mockProfile = profileSource()
    if (mockProfile) return String(mockProfile.readonly_reason || "")
    if (!managerProbeDone) return "Checking system power managers"
    if (powerManager !== "") return powerManager + " is active, so profile switching is disabled"
    if (!ppdActive) return "power-profiles-daemon is not running"
    if (!profileProbeDone) return "Checking power-profiles-daemon"
    if (profileError !== "") return profileError
    if (realProfiles.length === 0) return "No power profiles reported"
    return ""
  }

  readonly property bool profileAvailable: {
    var mockProfile = profileSource()
    if (mockProfile) return mockProfile.available === true
    return managerProbeDone && profileProbeDone && ppdActive && profileError === "" && realProfiles.length > 0
  }

  function canSwitchProfile(name) {
    return profileAvailable && readonlyReason === "" && !switching &&
      Model.isKnownProfile(name) && profiles.indexOf(name) >= 0
  }

  // ------------------------------------------------------------------- meta
  readonly property string packageMeta: {
    if (!hasTemp) return unavailableReason
    var source = doc.cpu.package_source || ""
    var label = doc.cpu.package_label || "CPU"
    if (source.indexOf("hwmon:") === 0) return source.slice(6) + " · " + label
    if (source.indexOf("thermal:") === 0) return "thermal zone · " + label
    return label
  }

  readonly property string coresText: {
    if (cores.length === 0) return "Not exposed"
    var values = []
    for (var i = 0; i < cores.length; i++) values.push(Model.formatTemp(cores[i].c, unit, false))
    return values.join(" / ")
  }

  readonly property string throttleSummary: {
    var t = doc.throttle || {}
    if (t.supported !== true) return "Counters not exposed"
    if (throttleActive) return "Active evidence"
    return "No counter change this session"
  }

  readonly property string throttleCounts: {
    var t = doc.throttle || {}
    if (t.supported !== true) return "—"
    return String(t.core_count || 0) + " core / " + String(t.package_count || 0) + " package"
  }

  readonly property string coolingSummary: {
    var c = doc.cooling || {}
    if (c.available !== true) return "Not exposed"
    if (c.active !== true) return "No active CPU cooling state"
    var parts = []
    var devices = Array.isArray(c.devices) ? c.devices : []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].cur > 0) {
        parts.push(String(devices[i].type) + " " + String(devices[i].cur) + "/" + String(devices[i].max))
      }
    }
    return parts.length > 0 ? parts.join(" · ") : "Active"
  }

  function mhz(value) {
    return Model.isFiniteNumber(value) ? String(Math.round(value)) + " MHz" : "—"
  }

  readonly property string freqText: {
    var f = doc.freq || {}
    if (f.available !== true) return "Not exposed"
    if (Model.isFiniteNumber(f.cur_min_mhz) && Model.isFiniteNumber(f.cur_max_mhz)) {
      if (f.cur_min_mhz === f.cur_max_mhz) return mhz(f.cur_max_mhz)
      return String(Math.round(f.cur_min_mhz)) + "–" + String(Math.round(f.cur_max_mhz)) + " MHz"
    }
    return "Not sampled"
  }

  readonly property string freqMeta: {
    var f = doc.freq || {}
    var pieces = []
    if (f.governor) pieces.push(String(f.governor))
    if (f.driver) pieces.push(String(f.driver))
    if (f.epp) pieces.push("EPP " + String(f.epp))
    return pieces.join(" · ")
  }

  readonly property string capText: {
    var f = doc.freq || {}
    if (f.capped === true) return "Capped at " + mhz(f.cap_mhz) + " (hardware " + mhz(f.cpuinfo_max_mhz) + ")"
    if (Model.isFiniteNumber(f.cpuinfo_max_mhz)) return "No policy cap (hardware " + mhz(f.cpuinfo_max_mhz) + ")"
    return "Not exposed"
  }

  readonly property string pstateText: {
    var p = doc.pstate || {}
    if (!p.kind) return "Not exposed"
    var pieces = [p.kind + "_pstate " + String(p.status || "unknown")]
    if (p.no_turbo === 1) pieces.push("turbo disabled")
    else if (p.no_turbo === 0) pieces.push("turbo enabled")
    if (Model.isFiniteNumber(p.turbo_pct)) pieces.push("turbo " + String(p.turbo_pct) + "%")
    return pieces.join(" · ")
  }

  readonly property string batterySourceNote: {
    if (!battery.present) return ""
    if (battery.power_source === "upower") {
      if (battery.status === "Charging" || battery.status === "Pending charge") {
        return "Watts come from UPower's charge rate (charger input, not CPU consumption)."
      }
      return "Watts come from UPower's change rate; sysfs power_now/current_now are unavailable."
    }
    if (battery.power_source === "sysfs:power_now") return "Watts read from battery power_now."
    if (battery.power_source === "sysfs:current_voltage") return "Watts calculated from current_now × voltage_now."
    return "Battery watts are not exposed."
  }

  readonly property string batteryTimeText: {
    if (!battery.present) return "—"
    if (battery.status !== "Discharging" && battery.status !== "Charging" && battery.status !== "Pending charge") return "—"
    return Model.formatDuration(battery.time_minutes)
  }

  readonly property string fanText: {
    if (fans.length === 0) return "No fan RPM sensor exposed"
    var parts = []
    for (var i = 0; i < fans.length; i++) {
      parts.push(String(fans[i].chip || "fan") + " · " + String(fans[i].label || "fan") + " " + String(fans[i].rpm) + " RPM")
    }
    return parts.join("\n")
  }

  readonly property var cpuFacts: {
    var facts = []
    if (!hasTemp) {
      facts.push({ label: "Package", value: unavailableReason || "Unavailable", color: stateColor })
    } else {
      facts.push({ label: "Package", value: Model.formatTemp(packageC, unit, true) })
      if (Model.isFiniteNumber(critC)) facts.push({ label: "Critical limit", value: Model.formatTemp(critC, unit, true) })
    }
    if (cores.length > 0) facts.push({ label: "Per core", value: coresText })
    facts.push({ label: "Frequency", value: freqText })
    facts.push({ label: "Governor", value: freqMeta || "Not exposed" })
    facts.push({ label: "Policy cap", value: capText })
    facts.push({ label: "P-state", value: pstateText })
    return facts
  }

  readonly property var throttleFacts: {
    var t = doc.throttle || {}
    var facts = []
    facts.push({ label: "Counter source", value: t.supported === true ? "thermal_throttle" : "Not exposed" })
    facts.push({ label: "Counters", value: throttleCounts })
    facts.push({ label: "CPU cooling", value: coolingSummary })
    facts.push({ label: "Last evidence", value: lastThrottleAt > 0 ? Math.round(throttleAgeSeconds) + " s ago" : "None this session", color: throttleActive ? Commons.Color.urgent : root.barForeground })
    return facts
  }

  readonly property var batteryFacts: {
    var facts = []
    if (!battery.present) {
      facts.push({ label: "Battery", value: "Not exposed" })
      facts.push({ label: "AC", value: battery.ac_known ? (battery.ac_online ? "Connected" : "Not connected") : "Not reported" })
      return facts
    }
    facts.push({ label: "State", value: battery.status || "Unknown" })
    facts.push({ label: "Charge", value: Model.isFiniteNumber(battery.percent) ? String(Math.round(battery.percent)) + "%" : "—" })
    facts.push({ label: "Power", value: Model.formatWatts(battery.power_w) + (battery.power_direction === "in" ? " ↑" : battery.power_direction === "out" ? " ↓" : "") })
    facts.push({ label: "Time", value: batteryTimeText })
    facts.push({ label: "AC", value: battery.ac_known ? (battery.ac_online ? "Connected" : "Not connected") : "Not reported" })
    if (Model.isFiniteNumber(battery.energy_wh) && Model.isFiniteNumber(battery.energy_full_wh)) {
      facts.push({ label: "Energy", value: battery.energy_wh.toFixed(1) + " / " + battery.energy_full_wh.toFixed(1) + " Wh" })
    }
    if (Model.isFiniteNumber(battery.cycle_count)) facts.push({ label: "Cycles", value: String(battery.cycle_count) })
    if (battery.count > 1) facts.push({ label: "Batteries", value: "Showing " + (battery.name || "first") + " of " + battery.count })
    return facts
  }

  readonly property var powerLimitFacts: {
    var facts = []
    for (var i = 0; i < powerLimits.length; i++) {
      var item = powerLimits[i]
      var name = String(item.constraint || "limit")
      if (name === "long_term") name = "PL1 long term"
      else if (name === "short_term") name = "PL2 short term"
      else if (name === "peak_power") name = "Peak power"
      var value = Model.formatWatts(item.watts, 0)
      if (Model.isFiniteNumber(item.max_watts)) value += " (max " + Model.formatWatts(item.max_watts, 0) + ")"
      facts.push({ label: String(item.domain || "package") + " · " + name, value: value })
    }
    return facts
  }

  readonly property var sensorFacts: {
    var facts = []
    for (var i = 0; i < sensors.length; i++) {
      var item = sensors[i]
      var label = String(item.label || item.chip || "sensor")
      if (item.chip && item.chip !== label) label = String(item.chip) + " · " + label
      facts.push({ label: label, value: Model.formatTemp(item.c, unit, true) })
    }
    return facts
  }

  readonly property var visibleWarnings: {
    var result = []
    for (var i = 0; i < warnings.length; i++) {
      var warning = String(warnings[i])
      if (warning.indexOf("No fan RPM") >= 0) continue
      if (warning.indexOf("Battery power is not exposed") >= 0 && Model.isFiniteNumber(battery.power_w)) continue
      result.push(warning)
    }
    return result
  }

  readonly property string lastUpdatedText: {
    if (runError !== "") return "Collector error"
    if (!gotDoc || lastUpdateMs <= 0) return "Waiting for first sample"
    var seconds = Math.max(0, Math.round((nowMs - lastUpdateMs) / 1000))
    if (seconds < 2) return "Updated just now"
    if (seconds < 60) return "Updated " + seconds + " s ago"
    return "Updated " + Math.floor(seconds / 60) + " min ago"
  }

  readonly property string tooltipText: {
    var lines = ["Thermal & Power"]
    if (runError !== "") lines.push(runError)
    if (!hasTemp) lines.push("CPU temperature unavailable")
    else lines.push("CPU " + Model.formatTemp(packageC, unit, true) + " · " + stateText(overall))
    if (battery.present) {
      var charge = Model.isFiniteNumber(battery.percent) ? String(Math.round(battery.percent)) + "%" : ""
      var watts = Model.isFiniteNumber(battery.power_w) ? " · " + Model.formatWatts(battery.power_w) : ""
      lines.push(battery.status + (charge ? " " + charge : "") + watts)
    }
    if (profileAvailable && activeProfile !== "") lines.push("Profile: " + Model.profileLabel(activeProfile))
    if (throttleActive) lines.push("Throttling evidence active")
    lines.push("Click for details")
    return lines.join("\n")
  }

  // ------------------------------------------------------------ helper/process
  Process {
    id: helperProc
    stdout: StdioCollector {
      id: helperOut
      waitForEnd: true
      onStreamFinished: root.acceptHelper(text)
    }
    stderr: StdioCollector {
      id: helperErr
      waitForEnd: true
      onStreamFinished: root.helperStderr = String(text).trim()
    }
    onExited: function(exitCode) {
      root.helperRunning = false
      root.refreshing = false
      root.helperExitCode = exitCode
      killTimer.stop()
      if (exitCode !== 0) {
        var lines = String(helperErr.text || root.helperStderr).trim().split("\n")
        var last = lines.length > 0 ? lines[lines.length - 1] : ""
        root.runError = "Helper failed (exit " + exitCode + ")" + (last ? ": " + last : "")
      }
    }
  }

  Timer {
    id: killTimer
    interval: 8000
    onTriggered: {
      if (!root.helperRunning) return
      helperProc.running = false
      root.helperRunning = false
      root.refreshing = false
      root.runError = "Collector timed out after 8 s"
    }
  }

  function runHelper() {
    if (helperRunning) return
    if (mockError !== "") {
      runError = mockError
      return
    }
    var command = ["python3", "-I", helperPath]
    if (mockName !== "") command.push("--mock", mockName)
    helperProc.command = command
    helperRunning = true
    refreshing = true
    runError = ""
    helperStderr = ""
    killTimer.restart()
    helperProc.running = true
  }

  function acceptHelper(text) {
    var raw = String(text || "").trim()
    if (raw === "") {
      runError = "Collector returned no data"
      return
    }
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (error) {
      runError = "Could not parse collector output"
      return
    }
    if (!parsed || parsed.schema !== 1) {
      runError = "Unsupported collector schema"
      return
    }
    processDocument(parsed)
  }

  function processDocument(parsed) {
    doc = parsed
    gotDoc = true
    lastUpdateMs = Date.now()
    runError = ""
    mockAux = parsed.mock_aux || null

    if (mockAux && mockName !== "" && mockSeeded !== mockName) {
      if (Array.isArray(mockAux.history_c)) {
        history = Model.seedHistory(mockAux.history_c, lastUpdateMs, cfg.historyMinutes * 60000)
      } else {
        history = []
      }
      mockSeeded = mockName
    } else if (hasTemp) {
      history = Model.appendHistory(history, lastUpdateMs, parsed.cpu.package_c,
        Math.max(60, Math.round(cfg.historyMinutes * 60000 / Math.max(1000, cfg.pollClosedSeconds * 1000))),
        cfg.historyMinutes * 60000)
    }

    updateThrottle(parsed, lastUpdateMs)
    updateBattery(parsed)
    updateNotifications()
  }

  function updateThrottle(parsed, now) {
    var t = parsed.throttle || {}
    if (t.supported === true) {
      if (throttlePrev) {
        var previous = throttlePrev
        if (Number(t.core_count) >= Number(previous.core_count) &&
            Number(t.package_count) >= Number(previous.package_count)) {
          var coreDelta = Math.max(0, Number(t.core_count) - Number(previous.core_count))
          var packageDelta = Math.max(0, Number(t.package_count) - Number(previous.package_count))
          if (coreDelta + packageDelta > 0) {
            recordThrottleEvent(now, coreDelta, packageDelta,
              Math.max(0, Number(t.core_total_ms) - Number(previous.core_total_ms)))
          }
        }
      }
      throttlePrev = {
        core_count: Number(t.core_count) || 0,
        package_count: Number(t.package_count) || 0,
        core_total_ms: Number(t.core_total_ms) || 0
      }
    } else {
      throttlePrev = null
    }

    if (mockAux && mockAux.throttle_delta) {
      lastThrottleAt = now
      if (now - lastMockEventAt > 5000) {
        lastMockEventAt = now
        var delta = mockAux.throttle_delta
        recordThrottleEvent(now, Number(delta.core || 0), Number(delta.package || 0), Number(delta.total_ms || 0))
      }
    }
  }

  function recordThrottleEvent(now, coreDelta, packageDelta, totalMs) {
    lastThrottleAt = now
    var events = throttleEvents.slice()
    events.unshift({ at: now, core: coreDelta, package: packageDelta, total_ms: totalMs })
    if (events.length > 8) events = events.slice(0, 8)
    throttleEvents = events
  }

  function upowerSnapshot() {
    if (mockAux) return mockAux.upower || {}
    var device = UPower.displayDevice
    if (!device || !device.isPresent) return { present: false, onBattery: UPower.onBattery }
    return {
      present: true,
      state: Model.upowerStateToString(device.state),
      percent: Number(device.percentage) * 100,
      changeRate: Number(device.changeRate),
      timeToFull: Number(device.timeToFull),
      timeToEmpty: Number(device.timeToEmpty),
      onBattery: UPower.onBattery
    }
  }

  function updateBattery(parsed) {
    var sysfs = parsed && parsed.battery ? parsed.battery : emptyBattery()
    var merged = Model.mergeBattery(sysfs, upowerSnapshot())
    var smooth = Model.smoothWatts(emaState, {
      watts: merged.power_w,
      source: merged.power_source,
      status: merged.status
    }, Date.now(), 15000)
    emaState = smooth.state
    merged.power_w = smooth.watts
    battery = merged
  }

  function updateNotifications() {
    var result = Model.updateNotificationState(notifState, {
      tempC: hasTemp ? packageC : null,
      watts: battery.power_w,
      discharging: battery.status === "Discharging"
    }, Date.now(), cfg)
    notifState = result.state
    if (result.notifyTemp) {
      enqueueNotification("temp", "CPU package stayed at or above " +
        Model.formatTemp(cfg.notifyTempC, unit, true) + " for " +
        String(cfg.notifyTempSeconds) + " s.")
    }
    if (result.notifyPower) {
      enqueueNotification("power", "Battery draw stayed at or above " +
        Model.formatWatts(cfg.notifyPowerW, 0) + " for " + String(cfg.notifyPowerSeconds) +
        " s while discharging.")
    }
  }

  function enqueueNotification(kind, message) {
    var queue = notifQueue.slice()
    queue.push({ kind: kind, message: message })
    notifQueue = queue
    drainNotifications()
  }

  function drainNotifications() {
    if (notifProc.running || notifQueue.length === 0) return
    var item = notifQueue[0]
    notifQueue = notifQueue.slice(1)
    var title = item.kind === "temp" ? "CPU temperature high" : "Battery draw high"
    var glyph = item.kind === "temp" ? "\uf2c7" : "\uf0e7"
    notifProc.command = [
      "omarchy-notification-send",
      "--app-name", "io.github.manish0467.thermal-power",
      "-u", "normal",
      "-g", glyph,
      title, item.message
    ]
    notifProc.running = true
  }

  Process {
    id: notifProc
    onExited: root.drainNotifications()
  }

  // --------------------------------------------------------------- profile
  Process {
    id: profileProbe
    command: [
      "busctl", "--json=short", "get-property",
      "org.freedesktop.UPower.PowerProfiles",
      "/org/freedesktop/UPower/PowerProfiles",
      "org.freedesktop.UPower.PowerProfiles",
      "ActiveProfile"
    ]
    stdout: StdioCollector {
      id: profileProbeOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: profileProbeErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.profileProbeRunning = false
      root.profileProbeDone = true
      if (exitCode === 0) {
        try {
          var reply = JSON.parse(String(profileProbeOut.text || "{}"))
          var name = String(reply.data || "")
          if (Model.isKnownProfile(name)) root.nativeProfile = name
          root.profileError = ""
        } catch (error) {
          root.profileError = "Could not parse the power profile D-Bus reply"
        }
      } else {
        root.profileError = "power-profiles-daemon did not answer the D-Bus read"
      }
      root.syncProfileList()
    }
  }

  Process {
    id: managerProbe
    command: [
      "systemctl", "is-active",
      "tuned.service", "tlp.service", "auto-cpufreq.service", "power-profiles-daemon.service"
    ]
    stdout: StdioCollector {
      id: managerProbeOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: managerProbeErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.managerProbeRunning = false
      root.managerProbeDone = true
      var lines = String(managerProbeOut.text || "").trim().split("\n")
      var names = ["tuned", "tlp", "auto-cpufreq"]
      root.powerManager = ""
      for (var i = 0; i < names.length; i++) {
        if (String(lines[i] || "") === "active") root.powerManager = names[i]
      }
      root.ppdActive = String(lines[3] || "") === "active"
      root.syncProfileList()
    }
  }

  function syncProfileList() {
    var list = ["power-saver", "balanced"]
    if (PowerProfiles.hasPerformanceProfile) list.push("performance")
    realProfiles = list
    if (!profileProbeDone) {
      var nativeName = Model.profileEnumToString(PowerProfiles.profile)
      if (nativeName !== "") nativeProfile = nativeName
    }
  }

  function probeProfile() {
    if (mockRaw !== "" || profileProbeRunning) return
    profileProbeRunning = true
    profileProbe.running = true
  }

  function probeManagers() {
    if (mockRaw !== "" || managerProbeRunning) return
    managerProbeRunning = true
    managerProbe.running = true
  }

  Process {
    id: switchProc
    stdout: StdioCollector {
      id: switchOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: switchErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.switching = false
      if (exitCode === 0) {
        root.nativeProfile = root.pendingProfile
        root.switchError = ""
        Qt.callLater(root.probeProfile)
        Qt.callLater(root.runHelper)
      } else {
        var lines = String(switchErr.text || "").trim().split("\n")
        root.switchError = lines.length > 0 && lines[0] !== ""
          ? lines[0]
          : "Profile switch failed (exit " + exitCode + ")"
      }
      root.pendingProfile = ""
    }
  }

  function switchProfile(name) {
    if (!canSwitchProfile(name)) return
    if (mockAux && mockAux.profile) {
      var copy = JSON.parse(JSON.stringify(mockAux.profile))
      copy.active = name
      mockAux = { scenario: mockAux.scenario, description: mockAux.description, profile: copy, upower: mockAux.upower, history_c: mockAux.history_c, throttle_delta: mockAux.throttle_delta }
      return
    }
    switching = true
    switchError = ""
    pendingProfile = name
    switchProc.command = ["omarchy-powerprofiles-set", "autodetect", name]
    switchProc.running = true
  }

  // --------------------------------------------------------------- history
  function historyRange() {
    if (!history || history.length === 0) return { min: 30, max: 100 }
    var result = Model.historyMinMax(history)
    if (!Model.isFiniteNumber(result.min) || !Model.isFiniteNumber(result.max)) return { min: 30, max: 100 }
    var low = Math.floor(result.min - 4)
    var high = Math.ceil(result.max + 4)
    if (high - low < 20) {
      var middle = (high + low) / 2
      low = Math.floor(middle - 10)
      high = Math.ceil(middle + 10)
    }
    return { min: Math.max(0, low), max: Math.min(120, high) }
  }

  function historyPath(ctx, width, height) {
    var points = history || []
    if (points.length < 2) return
    var range = historyRange()
    var span = Math.max(1, range.max - range.min)
    var start = points[0].t
    var end = points[points.length - 1].t
    var duration = Math.max(1, end - start)
    ctx.beginPath()
    for (var i = 0; i < points.length; i++) {
      var x = (points[i].t - start) / duration * width
      var y = height - (points[i].c - range.min) / span * height
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
  }

  function thresholdY(celsius, width, height) {
    var range = historyRange()
    var span = Math.max(1, range.max - range.min)
    return height - (celsius - range.min) / span * height
  }

  // --------------------------------------------------------------- open/close
  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    root.opened ? close() : open()
  }

  function refresh() {
    runHelper()
    probeManagers()
    probeProfile()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  onOpenedChanged: {
    if (opened) {
      runHelper()
      probeManagers()
      probeProfile()
      pollTimer.restart()
    }
  }

  onSettingsChanged: {
    if (mockRaw !== lastMockRaw) {
      lastMockRaw = mockRaw
      mockAux = null
      mockSeeded = ""
      doc = emptyDocument()
      gotDoc = false
      runError = ""
      throttlePrev = null
      lastThrottleAt = 0
      throttleEvents = []
      history = []
    }
    settingsDebounce.restart()
  }

  Component.onCompleted: {
    lastMockRaw = mockRaw
    updateBattery(emptyDocument())
  }

  Timer {
    id: startupTimer
    interval: 300
    running: true
    onTriggered: {
      root.startupDone = true
      root.refresh()
    }
  }

  Timer {
    id: settingsDebounce
    interval: 600
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: Math.max(1000, (root.opened ? root.cfg.pollOpenSeconds : root.cfg.pollClosedSeconds) * 1000)
    running: root.startupDone
    repeat: true
    onTriggered: root.runHelper()
  }

  Timer {
    id: uiTick
    interval: 5000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
    }
  }

  Connections {
    target: UPower.displayDevice
    ignoreUnknownSignals: true
    function onChangeRateChanged() { root.updateBattery(root.doc) }
    function onStateChanged() { root.updateBattery(root.doc) }
    function onPercentageChanged() { root.updateBattery(root.doc) }
    function onIsPresentChanged() { root.updateBattery(root.doc) }
  }

  Connections {
    target: PowerProfiles
    ignoreUnknownSignals: true
    function onProfileChanged() {
      if (root.mockAux) return
      var name = Model.profileEnumToString(PowerProfiles.profile)
      if (name !== "") root.nativeProfile = name
    }
    function onHasPerformanceProfileChanged() { root.syncProfileList() }
  }

  // -------------------------------------------------------------------- UI
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.cappedContentHeight(Style.space(620))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: flick.height

      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          var next = flick.contentY + dy * Style.space(36)
          flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, next))
        }
      }
      onTextKey: function(text, modifiers) {
        if (text === "r") root.refresh()
        else if (text === "o") root.showOtherSensors = !root.showOtherSensors
      }

      Flickable {
        id: flick
        width: parent.width - Style.space(8)
        height: Math.min(column.implicitHeight, parent.height)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        property bool panelOpened: root.opened
        onPanelOpenedChanged: if (panelOpened) contentY = 0

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // Header ---------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, statePill.height, refreshButton.height)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "Thermal & Power"
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                text: root.lastUpdatedText
                textFormat: Text.PlainText
                color: Util.alpha(root.barForeground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf021"
              tooltipText: "Refresh now (r)"
              enabled: !root.helperRunning
              onClicked: root.refresh()
            }

            Rectangle {
              id: statePill
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: statePillRow.implicitWidth + Style.space(16)
              height: statePillRow.implicitHeight + Style.space(8)
              radius: height / 2
              color: Util.alpha(root.stateColor, 0.14)
              border.width: 1
              border.color: Util.alpha(root.stateColor, 0.42)

              Row {
                id: statePillRow
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: Model.stateGlyph(root.overall)
                  textFormat: Text.PlainText
                  color: root.stateColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  text: root.stateText(root.overall)
                  textFormat: Text.PlainText
                  color: root.stateColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          // Hero -----------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroLeft.implicitHeight, chart.height)

            Column {
              id: heroLeft
              width: parent.width - chart.width - Style.space(16)
              spacing: Style.space(4)

              Text {
                text: root.hasTemp ? Model.formatTemp(root.packageC, root.unit, true) : "—"
                textFormat: Text.PlainText
                color: root.hasTemp ? root.stateColor : Util.alpha(root.barForeground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }
              Text {
                text: root.packageMeta
                textFormat: Text.PlainText
                color: Util.alpha(root.barForeground, 0.62)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: root.stateText(root.overall)
                textFormat: Text.PlainText
                color: root.stateColor
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Canvas {
              id: chart
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(150)
              height: Style.space(76)

              property real historyStamp: root.lastUpdateMs
              property color chartColor: root.stateColor
              property int warmRef: root.warmC
              property int hotRef: root.hotC
              onHistoryStampChanged: requestPaint()
              onChartColorChanged: requestPaint()
              onWarmRefChanged: requestPaint()
              onHotRefChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                if (!root.history || root.history.length < 2) {
                  ctx.strokeStyle = Util.alpha(root.barForeground, 0.18)
                  ctx.lineWidth = 1
                  ctx.beginPath()
                  ctx.moveTo(0, height - 2)
                  ctx.lineTo(width, height - 2)
                  ctx.stroke()
                  return
                }
                var range = root.historyRange()
                if (range.max > root.warmC && root.warmC > range.min) {
                  ctx.strokeStyle = Util.alpha("#e0a030", 0.45)
                  ctx.setLineDash([3, 4])
                  ctx.beginPath()
                  ctx.moveTo(0, root.thresholdY(root.warmC, width, height))
                  ctx.lineTo(width, root.thresholdY(root.warmC, width, height))
                  ctx.stroke()
                }
                if (range.max > root.hotC && root.hotC > range.min) {
                  ctx.strokeStyle = Util.alpha(Commons.Color.urgent, 0.5)
                  ctx.setLineDash([3, 4])
                  ctx.beginPath()
                  ctx.moveTo(0, root.thresholdY(root.hotC, width, height))
                  ctx.lineTo(width, root.thresholdY(root.hotC, width, height))
                  ctx.stroke()
                }
                ctx.setLineDash([])
                root.historyPath(ctx, width, height)
                ctx.lineTo(width, height)
                ctx.lineTo(0, height)
                ctx.closePath()
                ctx.fillStyle = Util.alpha(root.stateColor, 0.12)
                ctx.fill()
                root.historyPath(ctx, width, height)
                ctx.strokeStyle = root.stateColor
                ctx.lineWidth = 1.5
                ctx.lineJoin = "round"
                ctx.lineCap = "round"
                ctx.stroke()
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // CPU facts ------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "CPU"; foreground: root.barForeground }
            Repeater {
              model: root.cpuFacts
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(factLabel.implicitHeight, factValue.implicitHeight)
                Text {
                  id: factLabel
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: Util.alpha(root.barForeground, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: factValue
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: modelData.color || root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                  width: Math.max(0, parent.width - factLabel.implicitWidth - Style.space(12))
                  anchors.right: parent.right
                  elide: Text.ElideRight
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // Throttling -----------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "Throttling"; foreground: root.barForeground }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: Model.stateGlyph(root.throttleActive ? "throttling" : "normal")
                textFormat: Text.PlainText
                color: root.throttleActive ? Commons.Color.urgent : Util.alpha(root.barForeground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                text: root.throttleSummary
                textFormat: Text.PlainText
                color: root.throttleActive ? Commons.Color.urgent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: root.throttleActive
              }
            }
            Repeater {
              model: root.throttleFacts
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(throttleLabel.implicitHeight, throttleValue.implicitHeight)
                Text {
                  id: throttleLabel
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: Util.alpha(root.barForeground, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: throttleValue
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: modelData.color || root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                  width: Math.max(0, parent.width - throttleLabel.implicitWidth - Style.space(12))
                  anchors.right: parent.right
                  elide: Text.ElideRight
                }
              }
            }
            Text {
              width: parent.width
              text: "Zero counters do not prove the CPU is not throttled. Low frequency alone is not treated as throttling, and power-limit throttling is not directly measurable."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              lineHeight: 1.15
            }
            Repeater {
              model: root.throttleEvents
              delegate: Text {
                required property var modelData
                text: "· " + new Date(modelData.at).toLocaleTimeString(Qt.locale(), "hh:mm:ss") +
                  "  core +" + modelData.core + ", package +" + modelData.package
                textFormat: Text.PlainText
                color: Util.alpha(root.barForeground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              visible: root.throttleEvents.length === 0
              text: "No counter change observed since the panel started."
              textFormat: Text.PlainText
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // Power limits ---------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "Power limits"; foreground: root.barForeground }
            Text {
              visible: root.powerLimitFacts.length === 0
              text: "Package power limits are not exposed."
              textFormat: Text.PlainText
              color: Util.alpha(root.barForeground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Repeater {
              model: root.powerLimitFacts
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)
                Text {
                  id: limitLabel
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: Util.alpha(root.barForeground, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: limitValue
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                  anchors.right: parent.right
                }
              }
            }
            Text {
              width: parent.width
              text: "Read-only powercap limits. RAPL energy counters are not used because they are root-only on many laptops."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // Battery --------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "Battery"; foreground: root.barForeground }
            Repeater {
              model: root.batteryFacts
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(batteryLabel.implicitHeight, batteryValue.implicitHeight)
                Text {
                  id: batteryLabel
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: Util.alpha(root.barForeground, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: batteryValue
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  horizontalAlignment: Text.AlignRight
                  width: Math.max(0, parent.width - batteryLabel.implicitWidth - Style.space(12))
                  anchors.right: parent.right
                  elide: Text.ElideRight
                }
              }
            }
            Text {
              width: parent.width
              text: root.batterySourceNote
              visible: root.batterySourceNote !== ""
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // Fan ------------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "Fan"; foreground: root.barForeground }
            Text {
              width: parent.width
              text: root.fanText
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.fans.length > 0 ? root.barForeground : Util.alpha(root.barForeground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: root.fans.length > 0
              width: parent.width
              text: "Read-only RPM. This plugin does not control fans."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground }

          // Profile --------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(6)
            PanelSectionHeader { text: "Power profile"; foreground: root.barForeground }
            Row {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.profiles
                delegate: Button {
                  required property var modelData
                  text: Model.profileLabel(modelData)
                  iconText: Model.profileGlyph(modelData)
                  active: root.activeProfile === modelData
                  enabled: root.canSwitchProfile(modelData)
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.switchProfile(modelData)
                }
              }
              Text {
                visible: root.profiles.length === 0
                text: "No profiles reported"
                textFormat: Text.PlainText
                color: Util.alpha(root.barForeground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
            Text {
              visible: root.readonlyReason !== ""
              width: parent.width
              text: root.readonlyReason
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: root.switchError !== ""
              width: parent.width
              text: root.switchError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Commons.Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              width: parent.width
              text: "Switching uses omarchy-powerprofiles-set autodetect and saves Omarchy's AC/battery preference. It never uses sudo, pkexec or polkit."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.46)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Other sensors --------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            Button {
              width: parent.width
              text: "Other sensors (" + root.sensorFacts.length + ")"
              iconText: root.showOtherSensors ? "\uf077" : "\uf078"
              leftAlign: true
              bordered: true
              fontSize: Style.font.bodySmall
              onClicked: root.showOtherSensors = !root.showOtherSensors
            }
            Repeater {
              model: root.showOtherSensors ? root.sensorFacts : []
              delegate: Item {
                required property var modelData
                width: column.width
                height: Math.max(sensorLabel.implicitHeight, sensorValue.implicitHeight)
                Text {
                  id: sensorLabel
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: Util.alpha(root.barForeground, 0.58)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: Math.max(0, parent.width - sensorValue.implicitWidth - Style.space(12))
                }
                Text {
                  id: sensorValue
                  text: modelData.value
                  textFormat: Text.PlainText
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  anchors.right: parent.right
                }
              }
            }
            Text {
              visible: root.sensorFacts.length === 0
              text: "No additional temperature sensors exposed."
              textFormat: Text.PlainText
              color: Util.alpha(root.barForeground, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Warnings/footer ------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(2)
            Repeater {
              model: root.visibleWarnings
              delegate: Text {
                required property var modelData
                width: column.width
                text: "· " + modelData
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Util.alpha(root.barForeground, 0.46)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              width: parent.width
              text: "History is memory-only · " + String(root.cfg.pollClosedSeconds) + " s closed / " +
                String(root.cfg.pollOpenSeconds) + " s open · " + String(root.cfg.historyMinutes) + " min window"
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.barForeground, 0.38)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Rectangle {
        id: scrollbar
        visible: flick.contentHeight > flick.height + 1
        width: Style.space(3)
        height: Math.max(Style.space(28), flick.height * flick.height / Math.max(1, flick.contentHeight))
        radius: width / 2
        x: parent.width - width
        y: Math.min(Math.max(0, flick.height - height),
          flick.contentY / Math.max(1, flick.contentHeight - flick.height) * (flick.height - height))
        color: Util.alpha(root.barForeground, 0.28)
      }
    }
  }
}

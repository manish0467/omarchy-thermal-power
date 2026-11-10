// Pure, testable helpers for the Thermal & Power widget.
//
// This file deliberately has no QML or Quickshell imports. tests/test_model.js
// loads it directly with Node so formatting, state classification, smoothing,
// history, notification cooldown and battery merging can be tested without a
// running desktop session.

var SCHEMA_VERSION = 1;

var BAR_FIELDS = ["temp", "power", "profile"];

// Nerd Font glyphs. The three profile glyphs are the same ones Omarchy's
// built-in power panel uses.
var STATE_GLYPHS = {
  normal: "\uf2c7",       // thermometer-full
  warm: "\uf2c7",
  hot: "\uf2c7",
  throttling: "\uf071",   // exclamation-triangle
  unavailable: "\uf059"   // question-circle
};

var PROFILE_GLYPHS = {
  "power-saver": "\udb80\udf2a",
  "balanced": "\udb80\ude9a",
  "performance": "\udb81\udcc5"
};

var PROFILE_LABELS = {
  "power-saver": "Power saver",
  "balanced": "Balanced",
  "performance": "Performance"
};

var PROFILE_NAMES = ["power-saver", "balanced", "performance"];

function isFiniteNumber(value) {
  return typeof value === "number" && isFinite(value);
}

function toNumber(value, fallback) {
  var n = Number(value);
  return isFinite(n) ? n : fallback;
}

function clampNumber(value, low, high) {
  var n = toNumber(value, low);
  if (n < low) return low;
  if (n > high) return high;
  return n;
}

function sanitizeSensorLabel(text) {
  return String(text === null || text === undefined ? "" : text)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 48);
}

function sanitizeBarFields(raw, fallback) {
  var source = raw;
  if (typeof source === "string") source = [source];
  if (!Array.isArray(source)) source = fallback || ["temp", "power"];
  var result = [];
  for (var i = 0; i < source.length; i++) {
    var field = String(source[i] || "").toLowerCase();
    if (BAR_FIELDS.indexOf(field) >= 0 && result.indexOf(field) < 0) result.push(field);
  }
  if (result.length === 0) result = (fallback || ["temp", "power"]).slice();
  return result;
}

function sanitizeConfig(raw) {
  var cfg = raw || {};
  var warm = clampNumber(cfg.warmThreshold, 30, 105);
  var hot = clampNumber(cfg.hotThreshold, 31, 110);
  if (hot <= warm) hot = Math.min(110, warm + 1);
  return {
    warmC: Math.round(warm),
    hotC: Math.round(hot),
    unit: String(cfg.unit || "c").toLowerCase() === "f" ? "f" : "c",
    barFields: sanitizeBarFields(cfg.barFields),
    pollClosedSeconds: clampNumber(cfg.pollClosedSeconds, 3, 120),
    pollOpenSeconds: clampNumber(cfg.pollOpenSeconds, 1, 30),
    historyMinutes: clampNumber(cfg.historyMinutes, 1, 60),
    notifyTemp: cfg.notifyTemp === true,
    notifyTempC: clampNumber(cfg.notifyTempC, 40, 110),
    notifyTempSeconds: clampNumber(cfg.notifyTempSeconds, 10, 3600),
    notifyPower: cfg.notifyPower === true,
    notifyPowerW: clampNumber(cfg.notifyPowerW, 1, 250),
    notifyPowerSeconds: clampNumber(cfg.notifyPowerSeconds, 10, 3600),
    notifyCooldownMinutes: clampNumber(cfg.notifyCooldownMinutes, 1, 240)
  };
}

function classifyState(input) {
  var sample = input || {};
  if (!isFiniteNumber(sample.tempC) || sample.tempC < -40 || sample.tempC > 200) {
    return "unavailable";
  }
  if (sample.throttleActive === true) return "throttling";
  var hot = isFiniteNumber(sample.hotC) ? sample.hotC : 90;
  var warm = isFiniteNumber(sample.warmC) ? sample.warmC : 80;
  if (sample.tempC >= hot) return "hot";
  if (sample.tempC >= warm) return "warm";
  return "normal";
}

function stateGlyph(state) {
  return STATE_GLYPHS[state] || STATE_GLYPHS.unavailable;
}

function profileGlyph(name) {
  return PROFILE_GLYPHS[String(name || "")] || "";
}

function profileLabel(name) {
  return PROFILE_LABELS[String(name || "")] || "Unknown";
}

function isKnownProfile(name) {
  return PROFILE_NAMES.indexOf(String(name || "")) >= 0;
}

// Quickshell PowerProfile.Enum: 0 = power-saver, 1 = balanced, 2 = performance.
function profileEnumToString(value) {
  var n = toNumber(value, -1);
  if (n === 0) return "power-saver";
  if (n === 1) return "balanced";
  if (n === 2) return "performance";
  return "";
}

// Quickshell UPowerDeviceState.Enum, used only when UPower is the source.
function upowerStateToString(value) {
  var n = toNumber(value, 0);
  if (n === 1) return "Charging";
  if (n === 2) return "Discharging";
  if (n === 3) return "Empty";
  if (n === 4) return "Full";
  if (n === 5) return "Pending charge";
  if (n === 6) return "Pending discharge";
  return "Unknown";
}

function normalizeStatus(value) {
  var s = String(value || "").toLowerCase().replace(/\s+/g, " ");
  if (s === "charging") return "Charging";
  if (s === "discharging") return "Discharging";
  if (s === "full" || s === "fully-charged" || s === "fully charged") return "Full";
  if (s === "not charging") return "Not charging";
  if (s === "pending charge" || s === "pending-charge") return "Pending charge";
  if (s === "pending discharge" || s === "pending-discharge") return "Pending discharge";
  if (s === "empty") return "Empty";
  if (s === "unknown" || s === "") return "Unknown";
  return String(value || "").slice(0, 24);
}

function formatTempNumber(celsius, unit) {
  if (!isFiniteNumber(celsius)) return "--";
  var value = String(unit || "c").toLowerCase() === "f" ? celsius * 9 / 5 + 32 : celsius;
  return String(Math.round(value));
}

function formatTemp(celsius, unit, withUnit) {
  if (!isFiniteNumber(celsius)) return "--";
  var suffix = String(unit || "c").toLowerCase() === "f" ? "°F" : "°C";
  if (withUnit === false) suffix = "°";
  return formatTempNumber(celsius, unit) + suffix;
}

function formatWatts(watts, decimals) {
  if (!isFiniteNumber(watts)) return "--";
  var places = decimals === undefined ? 1 : decimals;
  var value = Math.abs(watts);
  if (places <= 0) return String(Math.round(value)) + " W";
  return (Math.round(value * 10) / 10).toFixed(1) + " W";
}

function formatWattsCompact(watts) {
  if (!isFiniteNumber(watts)) return "";
  var value = Math.abs(watts);
  var rounded = value >= 10 ? String(Math.round(value)) : String(Math.round(value * 10) / 10);
  return rounded + "W";
}

function formatDuration(minutes) {
  if (!isFiniteNumber(minutes) || minutes < 0) return "--";
  var total = Math.round(minutes);
  if (total < 60) return total + " min";
  var hours = Math.floor(total / 60);
  var mins = total % 60;
  if (mins === 0) return hours + " h";
  return hours + " h " + (mins < 10 ? "0" : "") + mins + " min";
}

function formatPowerCompact(battery) {
  var b = battery || {};
  if (b.present !== true) return "";
  var direction = "";
  if (b.status === "Charging" && b.power_w > 0.05) direction = "\u2191";
  else if (b.status === "Discharging" && b.power_w > 0.05) direction = "\u2193";
  if (isFiniteNumber(b.power_w)) {
    if (b.power_w <= 0.05 && b.ac_online === true && b.status !== "Discharging") return "AC";
    return formatWattsCompact(b.power_w) + direction;
  }
  if (b.status === "Charging") return "CHG";
  if (b.status === "Discharging") return "BAT";
  if (b.ac_online === true) return "AC";
  return "";
}

function buildBarLabel(input) {
  var sample = input || {};
  var fields = sanitizeBarFields(sample.fields);
  var parts = [];
  if (fields.indexOf("temp") >= 0 && isFiniteNumber(sample.tempC)) {
    parts.push(formatTemp(sample.tempC, sample.unit, false));
  } else if (fields.indexOf("temp") >= 0) {
    parts.push("--");
  }
  if (fields.indexOf("power") >= 0) {
    var power = formatPowerCompact(sample.battery);
    if (power) parts.push(power);
  }
  if (fields.indexOf("profile") >= 0 && isKnownProfile(sample.profile)) {
    parts.push(profileGlyph(sample.profile));
  }
  return parts.join(" ");
}

// Estimate the label width in bar icon slots. Text slots use Style.bar.iconSlot,
// which is 28 logical pixels in Omarchy 4.5.
function slotCountFor(label, iconSlot) {
  var text = String(label || "");
  if (text.length === 0) return 1;
  var slot = isFiniteNumber(iconSlot) && iconSlot > 0 ? iconSlot : 28;
  return Math.max(1, Math.min(4, Math.ceil((text.length * 7 + 26) / slot)));
}

function ema(previous, next, elapsedMs, tauMs) {
  if (!isFiniteNumber(next)) return previous;
  if (!isFiniteNumber(previous)) return next;
  var tau = isFiniteNumber(tauMs) && tauMs > 0 ? tauMs : 15000;
  var dt = isFiniteNumber(elapsedMs) && elapsedMs > 0 ? elapsedMs : 0;
  var alpha = 1 - Math.exp(-dt / tau);
  return previous + alpha * (next - previous);
}

// Keep power readings from flickering between sysfs and UPower. The state is
// reset whenever the source or charge direction changes so a 9 W idle reading
// does not slowly crawl toward a 40 W charging reading.
function smoothWatts(previousState, sample, now, tauMs) {
  var prev = previousState || {};
  var input = sample || {};
  var state = {
    value: prev.value,
    source: prev.source || "",
    status: prev.status || "",
    at: prev.at || 0
  };
  if (!isFiniteNumber(input.watts)) {
    state.value = null;
    state.source = input.source || "";
    state.status = input.status || "";
    state.at = now;
    return { state: state, watts: null };
  }
  var reset = !isFiniteNumber(prev.value) ||
    prev.source !== (input.source || "") ||
    prev.status !== (input.status || "");
  if (reset) {
    state.value = input.watts;
  } else {
    state.value = ema(prev.value, input.watts, now - prev.at, tauMs);
  }
  state.source = input.source || "";
  state.status = input.status || "";
  state.at = now;
  return { state: state, watts: state.value };
}

function appendHistory(history, timeMs, celsius, maxPoints, windowMs) {
  var source = Array.isArray(history) ? history : [];
  if (!isFiniteNumber(celsius)) return source;
  var points = source.slice();
  points.push({ t: timeMs, c: celsius });
  var cutoff = timeMs - (isFiniteNumber(windowMs) ? windowMs : 300000);
  while (points.length > 0 && points[0].t < cutoff) points.shift();
  var cap = isFiniteNumber(maxPoints) ? Math.max(2, maxPoints) : 200;
  while (points.length > cap) points.shift();
  return points;
}

function seedHistory(values, now, windowMs) {
  if (!Array.isArray(values) || values.length === 0) return [];
  var span = isFiniteNumber(windowMs) ? windowMs : 300000;
  var step = values.length > 1 ? span / (values.length - 1) : 0;
  var points = [];
  for (var i = 0; i < values.length; i++) {
    var c = Number(values[i]);
    if (isFinite(c)) points.push({ t: now - span + i * step, c: c });
  }
  return points;
}

function mergeBattery(sysfs, upower) {
  var s = sysfs || {};
  var u = upower || {};
  var present = s.present === true || u.present === true;
  var status = normalizeStatus(s.status);
  if (status === "Unknown") status = normalizeStatus(u.state);
  if (!present) status = "";

  var percent = null;
  if (isFiniteNumber(s.percent) && s.percent >= 0 && s.percent <= 100) {
    percent = Math.round(s.percent);
  } else if (isFiniteNumber(u.percent) && u.percent >= 0 && u.percent <= 100) {
    percent = Math.round(u.percent);
  }

  var watts = null;
  var source = "";
  if (isFiniteNumber(s.power_w) && s.power_w >= 0 && s.power_w <= 1000) {
    watts = Math.abs(s.power_w);
    source = s.power_source || "sysfs";
  } else if (isFiniteNumber(u.changeRate) && Math.abs(u.changeRate) <= 1000) {
    // UPower's changeRate is the charge/discharge rate. While charging it is
    // charger input, not CPU/battery consumption. The UI labels it as charging
    // power and the high-draw notification only considers discharging.
    watts = Math.abs(u.changeRate);
    source = "upower";
  }
  if (status === "Full" || status === "Not charging") {
    if (watts !== null && watts < 0.1) watts = 0;
  }

  var energy = isFiniteNumber(s.energy_wh) ? s.energy_wh : null;
  var full = isFiniteNumber(s.energy_full_wh) ? s.energy_full_wh : null;
  var timeMinutes = null;
  if (status === "Discharging" && isFiniteNumber(u.timeToEmpty) && u.timeToEmpty > 0) {
    timeMinutes = u.timeToEmpty / 60;
  } else if ((status === "Charging" || status === "Pending charge") &&
             isFiniteNumber(u.timeToFull) && u.timeToFull > 0) {
    timeMinutes = u.timeToFull / 60;
  } else if (watts !== null && watts > 0.1) {
    if (status === "Discharging" && energy !== null && energy > 0) {
      timeMinutes = energy / watts * 60;
    } else if ((status === "Charging" || status === "Pending charge") &&
               source !== "upower" && energy !== null && full !== null && full > energy) {
      timeMinutes = (full - energy) / watts * 60;
    }
  }
  if (isFiniteNumber(timeMinutes)) {
    timeMinutes = Math.max(0, Math.min(7 * 24 * 60, Math.round(timeMinutes)));
  } else {
    timeMinutes = null;
  }

  var acKnown = s.ac_known === true || u.present === true;
  var acOnline = s.ac_known === true ? s.ac_online === true : (u.present === true ? u.onBattery === false : false);

  return {
    present: present,
    name: String(s.name || ""),
    count: isFiniteNumber(s.count) ? s.count : (present ? 1 : 0),
    status: status,
    percent: percent,
    power_w: watts,
    power_source: source,
    power_direction: status === "Charging" ? "in" : (status === "Discharging" ? "out" : ""),
    energy_wh: energy,
    energy_full_wh: full,
    voltage_v: isFiniteNumber(s.voltage_v) ? s.voltage_v : null,
    cycle_count: isFiniteNumber(s.cycle_count) ? s.cycle_count : null,
    time_minutes: timeMinutes,
    ac_online: acOnline,
    ac_known: acKnown
  };
}

// Notifications are edge-triggered after a sustained threshold, with a
// per-notification cooldown. Power notifications require discharging: UPower's
// charging changeRate is charger input and must never be treated as system
// consumption.
function updateNotificationState(state, sample, now, config) {
  var previous = state || {};
  var s = {
    tempSince: isFiniteNumber(previous.tempSince) ? previous.tempSince : -1,
    powerSince: isFiniteNumber(previous.powerSince) ? previous.powerSince : -1,
    tempLast: isFiniteNumber(previous.tempLast) ? previous.tempLast : -1,
    powerLast: isFiniteNumber(previous.powerLast) ? previous.powerLast : -1
  };
  var input = sample || {};
  var cfg = config || {};
  var cooldownMs = clampNumber(cfg.notifyCooldownMinutes, 1, 240) * 60000;
  var notifyTemp = false;
  var notifyPower = false;

  var tempThreshold = toNumber(cfg.notifyTempC, 92);
  var tempSeconds = toNumber(cfg.notifyTempSeconds, 90);
  if (cfg.notifyTemp === true && isFiniteNumber(input.tempC) && input.tempC >= tempThreshold) {
    if (s.tempSince < 0) s.tempSince = now;
    if (now - s.tempSince >= tempSeconds * 1000 &&
        (s.tempLast < 0 || now - s.tempLast >= cooldownMs)) {
      notifyTemp = true;
      s.tempLast = now;
    }
  } else {
    s.tempSince = -1;
  }

  var powerThreshold = toNumber(cfg.notifyPowerW, 30);
  var powerSeconds = toNumber(cfg.notifyPowerSeconds, 60);
  if (cfg.notifyPower === true && input.discharging === true &&
      isFiniteNumber(input.watts) && input.watts >= powerThreshold) {
    if (s.powerSince < 0) s.powerSince = now;
    if (now - s.powerSince >= powerSeconds * 1000 &&
        (s.powerLast < 0 || now - s.powerLast >= cooldownMs)) {
      notifyPower = true;
      s.powerLast = now;
    }
  } else {
    s.powerSince = -1;
  }

  return { state: s, notifyTemp: notifyTemp, notifyPower: notifyPower };
}

function historyMinMax(history) {
  var points = Array.isArray(history) ? history : [];
  if (points.length === 0) return { min: null, max: null };
  var min = points[0].c;
  var max = points[0].c;
  for (var i = 1; i < points.length; i++) {
    if (!isFiniteNumber(points[i].c)) continue;
    if (points[i].c < min) min = points[i].c;
    if (points[i].c > max) max = points[i].c;
  }
  return { min: min, max: max };
}

// Node-only exports for tests/test_model.js. QML imports this file directly
// and never evaluates this branch.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    SCHEMA_VERSION: SCHEMA_VERSION,
    BAR_FIELDS: BAR_FIELDS,
    isFiniteNumber: isFiniteNumber,
    clampNumber: clampNumber,
    sanitizeSensorLabel: sanitizeSensorLabel,
    sanitizeBarFields: sanitizeBarFields,
    sanitizeConfig: sanitizeConfig,
    classifyState: classifyState,
    stateGlyph: stateGlyph,
    profileGlyph: profileGlyph,
    profileLabel: profileLabel,
    isKnownProfile: isKnownProfile,
    profileEnumToString: profileEnumToString,
    upowerStateToString: upowerStateToString,
    normalizeStatus: normalizeStatus,
    formatTempNumber: formatTempNumber,
    formatTemp: formatTemp,
    formatWatts: formatWatts,
    formatWattsCompact: formatWattsCompact,
    formatDuration: formatDuration,
    formatPowerCompact: formatPowerCompact,
    buildBarLabel: buildBarLabel,
    slotCountFor: slotCountFor,
    ema: ema,
    smoothWatts: smoothWatts,
    appendHistory: appendHistory,
    seedHistory: seedHistory,
    mergeBattery: mergeBattery,
    updateNotificationState: updateNotificationState,
    historyMinMax: historyMinMax
  };
}

#!/usr/bin/env node
"use strict";

const assert = require("assert");
const Model = require("../Model.js");

let count = 0;
function test(name, fn) {
  count += 1;
  try {
    fn();
    console.log("ok " + count + " - " + name);
  } catch (error) {
    console.error("not ok " + count + " - " + name);
    throw error;
  }
}

function close(actual, expected, epsilon) {
  assert.ok(Math.abs(actual - expected) <= (epsilon || 1e-6),
    "expected " + expected + ", got " + actual);
}

test("clamps numeric settings and repairs hot <= warm", () => {
  const cfg = Model.sanitizeConfig({
    warmThreshold: 95,
    hotThreshold: 80,
    unit: "F",
    barFields: ["profile", "temp", "temp", "bogus"],
    pollClosedSeconds: 1,
    pollOpenSeconds: 99,
    historyMinutes: 500
  });
  assert.strictEqual(cfg.warmC, 95);
  assert.strictEqual(cfg.hotC, 96);
  assert.strictEqual(cfg.unit, "f");
  assert.deepStrictEqual(cfg.barFields, ["profile", "temp"]);
  assert.strictEqual(cfg.pollClosedSeconds, 3);
  assert.strictEqual(cfg.pollOpenSeconds, 30);
  assert.strictEqual(cfg.historyMinutes, 60);
});

test("default bar fields keep profile out of the compact label", () => {
  const fields = Model.sanitizeBarFields(undefined);
  assert.deepStrictEqual(fields, ["temp", "power"]);
  assert.deepStrictEqual(Model.sanitizeBarFields([]), ["temp", "power"]);
});

test("classifies normal, warm, hot, throttling and unavailable", () => {
  const base = { warmC: 80, hotC: 90, throttleActive: false };
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: 47 })), "normal");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: 80 })), "warm");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: 89.9 })), "warm");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: 90 })), "hot");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: 47, throttleActive: true })), "throttling");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: null })), "unavailable");
  assert.strictEqual(Model.classifyState(Object.assign({}, base, { tempC: NaN })), "unavailable");
});

test("formats Celsius and Fahrenheit with degree sign", () => {
  assert.strictEqual(Model.formatTemp(47.4, "c", false), "47°");
  assert.strictEqual(Model.formatTemp(47.4, "c", true), "47°C");
  assert.strictEqual(Model.formatTemp(47, "f", true), "117°F");
  assert.strictEqual(Model.formatTemp(null, "c", true), "--");
});

test("formats compact watts with discharge and charge arrows", () => {
  const discharging = { present: true, status: "Discharging", power_w: 9.8, ac_online: false };
  const charging = { present: true, status: "Charging", power_w: 24.4, ac_online: true };
  assert.strictEqual(Model.formatPowerCompact(discharging), "9.8W↓");
  assert.strictEqual(Model.formatPowerCompact(charging), "24W↑");
  assert.strictEqual(Model.formatPowerCompact({ present: true, status: "Full", power_w: 0, ac_online: true }), "AC");
  assert.strictEqual(Model.formatPowerCompact({ present: false }), "");
});

test("builds the default bar label and keeps profile optional", () => {
  const battery = { present: true, status: "Discharging", power_w: 24, ac_online: false };
  assert.strictEqual(Model.buildBarLabel({
    tempC: 47, unit: "c", battery, profile: "balanced", fields: ["temp", "power"]
  }), "47° 24W↓");
  assert.strictEqual(Model.buildBarLabel({
    tempC: 47, unit: "c", battery, profile: "balanced", fields: ["temp", "power", "profile"]
  }), "47° 24W↓ \udb80\ude9a");
  assert.strictEqual(Model.buildBarLabel({
    tempC: null, unit: "c", battery: { present: false }, fields: ["temp"]
  }), "--");
});

test("estimates bar slots without exceeding four", () => {
  assert.strictEqual(Model.slotCountFor(""), 1);
  assert.strictEqual(Model.slotCountFor("47°"), 2);
  assert.strictEqual(Model.slotCountFor("47° 24W↓"), 3);
  assert.strictEqual(Model.slotCountFor("a very long label"), 4);
});

test("merges sysfs watts first and UPower as a fallback", () => {
  const merged = Model.mergeBattery(
    { present: true, status: "Discharging", percent: 62, power_w: 8.2, power_source: "sysfs:power_now", energy_wh: 21.2, energy_full_wh: 34.6, ac_known: true, ac_online: false },
    { present: true, state: "Discharging", percent: 62, changeRate: 9.8, onBattery: true }
  );
  assert.strictEqual(merged.power_w, 8.2);
  assert.strictEqual(merged.power_source, "sysfs:power_now");
  assert.strictEqual(merged.time_minutes, 155);

  const fallback = Model.mergeBattery(
    { present: true, status: "Discharging", percent: 62, power_w: null, energy_wh: 21.2, energy_full_wh: 34.6, ac_known: true, ac_online: false },
    { present: true, state: "Discharging", percent: 62, changeRate: 9.8, onBattery: true }
  );
  assert.strictEqual(fallback.power_w, 9.8);
  assert.strictEqual(fallback.power_source, "upower");
  assert.strictEqual(fallback.time_minutes, 130);
});

test("UPower charge rate is marked as charging input, not discharge", () => {
  const merged = Model.mergeBattery(
    { present: true, status: "Charging", percent: 75, power_w: null, energy_wh: 25.8, energy_full_wh: 34.6, ac_known: true, ac_online: true },
    { present: true, state: "Charging", percent: 75, changeRate: 24.4, onBattery: false }
  );
  assert.strictEqual(merged.power_w, 24.4);
  assert.strictEqual(merged.power_direction, "in");
  assert.strictEqual(merged.time_minutes, null);

  const timed = Model.mergeBattery(
    { present: true, status: "Charging", percent: 75, power_w: null, energy_wh: 25.8, energy_full_wh: 34.6, ac_known: true, ac_online: true },
    { present: true, state: "Charging", percent: 75, changeRate: 24.4, timeToFull: 3600, onBattery: false }
  );
  assert.strictEqual(timed.time_minutes, 60);
});

test("smoothing resets on source or direction change", () => {
  const first = Model.smoothWatts({}, { watts: 10, source: "upower", status: "Discharging" }, 1000, 15000);
  assert.strictEqual(first.watts, 10);
  const second = Model.smoothWatts(first.state, { watts: 20, source: "upower", status: "Discharging" }, 11000, 15000);
  assert.ok(second.watts > 10 && second.watts < 20);
  const reset = Model.smoothWatts(second.state, { watts: 24.4, source: "upower", status: "Charging" }, 12000, 15000);
  assert.strictEqual(reset.watts, 24.4);
});

test("history is windowed and capped", () => {
  let history = [];
  history = Model.appendHistory(history, 0, 40, 5, 1000);
  history = Model.appendHistory(history, 500, 41, 5, 1000);
  history = Model.appendHistory(history, 1600, 42, 5, 1000);
  assert.deepStrictEqual(history.map(p => p.c), [42]);
  history = Model.appendHistory(history, 1700, 43, 2, 5000);
  assert.deepStrictEqual(history.map(p => p.c), [42, 43]);
});

test("seeded history ends at now and spans the requested window", () => {
  const seeded = Model.seedHistory([40, 41, 42], 10000, 2000);
  assert.deepStrictEqual(seeded.map(p => p.t), [8000, 9000, 10000]);
});

test("temperature notification needs sustain time and cooldown", () => {
  const cfg = {
    notifyTemp: true, notifyTempC: 92, notifyTempSeconds: 90,
    notifyPower: false, notifyCooldownMinutes: 15
  };
  let result = Model.updateNotificationState({}, { tempC: 93 }, 0, cfg);
  assert.strictEqual(result.notifyTemp, false);
  result = Model.updateNotificationState(result.state, { tempC: 93 }, 89999, cfg);
  assert.strictEqual(result.notifyTemp, false);
  result = Model.updateNotificationState(result.state, { tempC: 93 }, 90000, cfg);
  assert.strictEqual(result.notifyTemp, true);
  result = Model.updateNotificationState(result.state, { tempC: 93 }, 120000, cfg);
  assert.strictEqual(result.notifyTemp, false);
  result = Model.updateNotificationState(result.state, { tempC: 93 }, 90000 + 15 * 60000, cfg);
  assert.strictEqual(result.notifyTemp, true);
});

test("power notification only fires while discharging", () => {
  const cfg = {
    notifyTemp: false,
    notifyPower: true, notifyPowerW: 30, notifyPowerSeconds: 60,
    notifyCooldownMinutes: 15
  };
  let result = Model.updateNotificationState({}, { watts: 40, discharging: false, tempC: 47 }, 0, cfg);
  assert.strictEqual(result.notifyPower, false);
  result = Model.updateNotificationState(result.state, { watts: 40, discharging: true, tempC: 47 }, 1000, cfg);
  assert.strictEqual(result.notifyPower, false);
  result = Model.updateNotificationState(result.state, { watts: 40, discharging: true, tempC: 47 }, 61000, cfg);
  assert.strictEqual(result.notifyPower, true);
});

test("charging watts cannot trigger the high-draw notification", () => {
  const cfg = {
    notifyTemp: false,
    notifyPower: true, notifyPowerW: 30, notifyPowerSeconds: 60,
    notifyCooldownMinutes: 15
  };
  let state = {};
  for (let i = 0; i < 10; i += 1) {
    const result = Model.updateNotificationState(state, { watts: 24.4, discharging: false }, i * 60000, cfg);
    state = result.state;
    assert.strictEqual(result.notifyPower, false);
  }
});

test("profile enums and labels are allow-listed", () => {
  assert.strictEqual(Model.profileEnumToString(0), "power-saver");
  assert.strictEqual(Model.profileEnumToString(1), "balanced");
  assert.strictEqual(Model.profileEnumToString(2), "performance");
  assert.strictEqual(Model.profileEnumToString(9), "");
  assert.strictEqual(Model.isKnownProfile("balanced"), true);
  assert.strictEqual(Model.isKnownProfile("../../evil"), false);
  assert.strictEqual(Model.profileGlyph("balanced"), "\udb80\ude9a");
  assert.strictEqual(Model.profileGlyph("power-saver"), "\udb80\udf2a");
  assert.strictEqual(Model.profileGlyph("performance"), "\udb81\udcc5");
});

test("sensor labels are stripped of controls and capped", () => {
  assert.strictEqual(Model.sanitizeSensorLabel("  Core\u0000 0\n"), "Core 0");
  assert.ok(Model.sanitizeSensorLabel("x".repeat(100)).length <= 48);
});

console.log("# model tests passed: " + count);

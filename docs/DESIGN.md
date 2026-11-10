# Design

## Goals

`io.github.manish0467.thermal-power` is an Omarchy bar widget that answers four questions without
requiring root:

1. How hot is the CPU package, and how has it changed recently?
2. Is there direct evidence that the CPU is throttling?
3. What is the battery doing, including watts and AC state?
4. Which power profile is active, and can the user switch it explicitly?

It must degrade honestly. Missing kernel data is shown as unavailable, not invented as zero, and the
plugin must not add a daemon, network access, privileged helper, fan control or hidden profile
changes.

## Architecture

```text
BarWidget.qml
  └── compact BarIconButton label
  └── loads Panel.qml (one panel instance per widget)

Panel.qml
  ├── helper/thermal_power.py   short-lived, python3 -I, read-only sysfs -> JSON schema 1
  ├── Quickshell UPower         native D-Bus battery fallback
  ├── Quickshell PowerProfiles  native profile enum and performance support
  ├── busctl read               exact ActiveProfile probe
  ├── systemctl is-active       conflict check for tuned/TLP/auto-cpufreq/PPD
  └── Model.js                  pure formatting, state, history, smoothing, notifications

Model.js
  └── no QML imports; loaded by Node tests
```

### Why a Python helper

There is no portable QML API for `hwmon`, thermal zones, throttle counters or powercap limits.
Quickshell can read files, but normalizing dozens of optional sysfs shapes, labels and units in QML
would be harder to test. A short-lived Python standard-library process keeps the collection logic
testable with Python 3.9 and 3.14, avoids a long-running daemon, and keeps memory bounded.

The shell invokes it with argv:

```text
python3 -I <plugin>/helper/thermal_power.py
```

`-I` isolates the process from user site-packages and environment variables. No shell is involved,
so sensor labels and profile names cannot become shell syntax. The helper exits after writing one
JSON document. There is no plugin state directory.

### Why QML still owns timers and UI

Quickshell already owns the panel lifecycle, keyboard handling, theme, UPower and PowerProfiles.
Keeping timers, history and UI in QML avoids a second event loop and lets the widget use native
Quickshell properties without a D-Bus client library.

## Data flow

- While the panel is closed, the helper runs every 10 s.
- While it is open, the helper runs every 2 s.
- Each JSON document is schema-checked (`schema: 1`) and parsed by `Panel.qml`.
- Battery data merges sysfs and native UPower. Sysfs `power_now` wins; `current_now × voltage_now` is
  next; UPower `ChangeRate` is the fallback.
- Battery watts are smoothed with a 15 s EMA. The state resets when the source or charge/discharge
  status changes, so a discharge reading does not slowly drift into a charging reading.
- History is kept for the configured 1–60 minutes, default 5, in memory only. It is lost when the
  shell restarts.
- Notification sustain timers and cooldowns are also memory-only.

## JSON schema 1

The helper emits one object. Unknown future keys are ignored by the UI.

```json
{
  "schema": 1,
  "generated_at": 0,
  "mock": null,
  "cpu": {
    "available": true,
    "package_c": 47.0,
    "package_label": "Package id 0",
    "package_source": "hwmon:coretemp",
    "crit_c": 100.0,
    "cores": [{"label": "Core 0", "c": 46.0}],
    "sensors": [{"chip": "nvme", "label": "Composite", "c": 34.9,
                 "crit_c": 81.8, "source": "hwmon"}],
    "max_c": 47.0
  },
  "fans": [{"chip": "thinkpad", "label": "fan1", "rpm": 2400}],
  "cooling": {
    "available": true,
    "active": false,
    "devices": [{"type": "Processor", "cur": 0, "max": 10, "cpu": true}],
    "other_count": 0
  },
  "throttle": {
    "supported": true,
    "cpu_count": 8,
    "core_count": 0,
    "package_count": 0,
    "core_total_ms": 0,
    "package_total_ms": 0,
    "core_max_ms": 0,
    "package_max_ms": 0
  },
  "freq": {
    "available": true,
    "policy_count": 8,
    "driver": "intel_pstate",
    "governor": "powersave",
    "epp": "power",
    "cur_min_mhz": 1238,
    "cur_max_mhz": 4500,
    "scaling_max_mhz": 4500,
    "cap_mhz": 4500,
    "cpuinfo_max_mhz": 4500,
    "capped": false,
    "boost": null
  },
  "pstate": {
    "kind": "intel",
    "status": "active",
    "no_turbo": 0,
    "turbo_pct": 48,
    "max_perf_pct": 100,
    "min_perf_pct": 7,
    "hwp_dynamic_boost": null
  },
  "power_limits": [
    {"domain": "package-0", "constraint": "long_term",
     "watts": 19.0, "max_watts": 28.0}
  ],
  "battery": {
    "present": true,
    "name": "BAT0",
    "count": 1,
    "status": "Discharging",
    "percent": 62,
    "energy_wh": 21.2,
    "energy_full_wh": 34.6,
    "charge_ah": null,
    "charge_full_ah": null,
    "voltage_v": 11.6,
    "cycle_count": 229,
    "power_w": null,
    "power_source": "",
    "power_direction": "",
    "ac_online": false,
    "ac_known": true,
    "ac_name": "AC"
  },
  "warnings": ["Battery power is not exposed (power_now/current_now unreadable)."]
}
```

Values that cannot be read are `null` (or empty arrays/strings), never fabricated. `cpu.available`
is false when no CPU temperature source is found. `cooling.active` is true only when a recognised CPU
cooling device has `cur_state > 0`.

## CPU package selection

The helper does not assume `hwmon0`. It discovers hwmon chips and thermal zones by name:

1. Prefer known CPU chips (`coretemp`, `k10temp`, `zenpower`, `cpu_thermal`, `soc_thermal`).
2. Within the best chip, prefer explicit package labels (`package`, `physical id`, `tdie`, `tctl`,
   `cpu package`, `soc`), then the hottest matching reading.
3. Fall back to a recognised CPU thermal-zone type (`x86_pkg_temp`, `TCPU`, `cpu-thermal`,
   `acpitz`, and related names).
4. If no package label or known zone exists, use the hottest reading from the CPU chip or the
   hottest thermal zone.
5. Report the selected source in the panel (`hwmon:…` or `thermal zone …`).

The “Other sensors” group excludes the selected package source and avoids duplicating an ACPI
thermal zone with an identically named hwmon chip. It includes NVMe, ACPI and other readable sensors,
up to 16 entries.

## States and thresholds

`Model.classifyState` is pure and testable:

- No finite temperature, or a temperature outside −40…200 °C: `unavailable`.
- Throttling evidence: `throttling` (takes priority over hot/warm).
- `tempC >= hotC`: `hot`.
- `tempC >= warmC`: `warm`.
- Otherwise: `normal`.

Defaults are 80 °C warm and 90 °C hot. They are display thresholds only. The manifest labels them as
starting points; the README repeats that they are not universal hardware limits. The plugin never
changes firmware, power limits or cooling behaviour.

## Throttling evidence

Direct counter data comes from per-CPU `thermal_throttle` files. `Panel.qml` compares consecutive
documents and records an event when core or package counters increase. CPU cooling devices whose
`cur_state > 0` are also evidence.

The design deliberately does **not** claim certainty:

- Zero counters do not prove “not throttled”; the counters may not be exposed or may not cover every
  throttling mechanism.
- Low frequency alone is not treated as throttling.
- Power-limit throttling (PL1/PL2) is not directly measurable without privileged MSR/RAPL access.
- A detected event colors the state for 15 s and is logged in the panel for the session.

## Power and battery

The helper tries, in order:

1. Battery `power_now` (µW).
2. `current_now` × `voltage_now` when both are readable.
3. Native UPower `ChangeRate` as a fallback in QML.

It never uses RAPL energy counters as a battery or CPU-power estimate. On many laptops those counters
are root-only; the plugin displays readable powercap limits instead and says so.

While charging, UPower’s `ChangeRate` is charger input, not battery/CPU consumption. The panel labels
this explicitly. Time remaining uses UPower’s `TimeToEmpty`/`TimeToFull` when readable; otherwise a
sysfs energy estimate is used only when the watts source is actually the battery. The high-draw
notification requires `Discharging`.

## Power profiles

Quickshell’s native `PowerProfiles` provides the current enum and whether performance is supported.
The panel separately runs one `busctl` read of `ActiveProfile` to avoid relying on Python/PyGObject
bindings and to keep the profile path explicit.

Switching is deliberately narrow:

- Only `power-saver`, `balanced`, and `performance` are accepted.
- Performance is offered only if advertised by power-profiles-daemon.
- A switch happens only on an explicit click.
- The command is exactly `omarchy-powerprofiles-set autodetect <profile>` with argv, no shell.
- If tuned, TLP or auto-cpufreq is active, switching is disabled with an explanation.
- If PPD is missing or conflicts, the switch buttons are disabled and the reason is shown.

`omarchy-powerprofiles-set autodetect` writes Omarchy’s own preferences for the current power source:
`~/.local/state/omarchy/powerprofiles/ac` and
`~/.local/state/omarchy/powerprofiles/battery`. This is intentionally disclosed in the README and
maintainer notes because it is a file side effect that marketplace reviewers should know about.
The plugin does not directly write those files.

## Notifications

Notifications are off by default. When enabled:

- Temperature: sustained at or above the configured threshold for the configured time (default
  92 °C for 90 s).
- Battery draw: sustained at or above the configured watts for the configured time (default 30 W for
  60 s), only while discharging.
- Per-notification cooldown defaults to 15 minutes.
- Delivery uses `omarchy-notification-send` with normal urgency and an app name/id.
- All sustain/cooldown state is in memory.

## Security and privacy

- No network use.
- No sudo, pkexec, polkit rule, setuid helper or root workaround.
- No sysfs writes, no fan control, no SMART, no package installation.
- Fixed argv arrays; no shell interpolation from sensor labels or profile names.
- Fixed profile allow-list.
- Read-only helper; invalid mock paths are rejected and mock scenarios cannot escape the `mock/`
  directory.
- No telemetry and no plugin-owned persisted state.
- The only intentional runtime side effect is the Omarchy preference-file write after an explicit
  profile click.

## Compatibility and degradation

- Tested on Omarchy 4.5.0-3. `omarchy-version` is authoritative; `/usr/share/omarchy/version` can be
  stale.
- Python 3.9 and 3.14 are tested.
- UPower is expected; without it battery fallback is unavailable and the panel says so.
- PPD is optional; the rest of the panel still works.
- No hardware-specific paths or `hwmonN` assumptions.
- Fan RPM and cooling devices are shown when exposed; otherwise the panel says they are not exposed.

## Rejected alternatives

- **Long-running Python daemon:** more state, more failure modes, higher idle cost.
- **PyGObject/UPower or powerprofilesctl Python bindings:** unnecessary dependency and a known
  interpreter-shutdown race risk under Python 3.14.
- **Direct PPD D-Bus setter:** would desynchronise Omarchy’s saved AC/battery preference.
- **RAPL energy counters for CPU power:** root-only on many systems and easy to misinterpret.
- **Low frequency as a throttling signal:** not reliable.
- **Fan control or root helper:** outside the plugin’s read-only scope.
- **Arbitrary profile names:** unacceptable command-injection surface.

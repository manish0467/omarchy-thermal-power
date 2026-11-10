#!/usr/bin/env python3
"""Read-only thermal, power and battery collector for the Omarchy widget.

The helper is deliberately small and uses only the Python standard library. It
reads /sys as the invoking user, normalizes the data to a stable JSON document,
and never writes to sysfs, never escalates privileges and never touches the
network.

Python 3.9 and newer are supported. The JSON schema is documented in
docs/DESIGN.md and is validated by tests/test_helper.py.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

SCHEMA_VERSION = 1
MAX_READ = 4096
TEMP_MIN_MC = -40000
TEMP_MAX_MC = 200000
MAX_SENSORS = 16
MAX_CORES = 16
MAX_POWER_LIMITS = 16

HWMON_RE = re.compile(r"^hwmon\d+$")
ZONE_RE = re.compile(r"^thermal_zone\d+$")
COOLING_RE = re.compile(r"^cooling_device\d+$")
POLICY_RE = re.compile(r"^policy\d+$")
CPU_RE = re.compile(r"^cpu\d+$")
TEMP_INPUT_RE = re.compile(r"^temp(\d+)_input$")
FAN_INPUT_RE = re.compile(r"^fan(\d+)_input$")
CONSTRAINT_RE = re.compile(r"^constraint_(\d+)_power_limit_uw$")
MOCK_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

CPU_CHIP_NAMES = {
    "coretemp", "k10temp", "zenpower", "cpu_thermal", "soc_thermal", "acpitz",
}
CPU_ZONE_TYPES = {
    "x86_pkg_temp", "tcpu", "cpu-thermal", "cpu_thermal", "soc_thermal", "acpitz",
}
CPU_COOLING_TYPES = {
    "processor", "intel_powerclamp", "powerclamp", "k10temp", "acpitz",
    "x86_pkg_temp", "tcpu",
}

PACKAGE_LABEL_HINTS = (
    "package", "physical id", "tdie", "tctl", "cpu package", "soc",
)

ZONE_PRIORITY = {
    "x86_pkg_temp": 0,
    "tcpu": 1,
    "cpu-thermal": 2,
    "cpu_thermal": 2,
    "soc_thermal": 2,
    "acpitz": 4,
}


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

class Reader:
    """Read-only view of a sysfs-like tree."""

    def __init__(self, root):
        self.root = Path(root)

    def _path(self, rel):
        parts = Path(rel).parts
        if ".." in parts or Path(rel).is_absolute():
            raise ValueError("invalid relative path")
        return self.root.joinpath(*parts)

    def read(self, rel, limit=MAX_READ):
        try:
            with self._path(rel).open("rb") as handle:
                data = handle.read(limit)
        except OSError:
            return None
        except ValueError:
            return None
        return data.decode("utf-8", "replace").strip()

    def listdir(self, rel):
        try:
            return sorted(os.listdir(str(self._path(rel))))
        except OSError:
            return []
        except ValueError:
            return []

    def exists(self, rel):
        try:
            return self._path(rel).exists()
        except (OSError, ValueError):
            return False


class MockReader(Reader):
    """In-memory reader used by the preview/test fixtures."""

    def __init__(self, files, errors=None):
        self.files = {}
        self.errors = dict(errors or {})
        for key, value in (files or {}).items():
            key = normalize_rel(key)
            if key and not any(part == ".." for part in key.split("/")):
                self.files[key] = "" if value is None else str(value)

    def read(self, rel, limit=MAX_READ):
        key = normalize_rel(rel)
        if key in self.errors:
            return None
        value = self.files.get(key)
        if value is None:
            return None
        return value.strip()[:limit]

    def listdir(self, rel):
        prefix = normalize_rel(rel).rstrip("/") + "/"
        names = set()
        for key in self.files:
            if key.startswith(prefix):
                rest = key[len(prefix):]
                if rest:
                    names.add(rest.split("/", 1)[0])
        for key in self.errors:
            if key.startswith(prefix):
                rest = key[len(prefix):]
                if rest:
                    names.add(rest.split("/", 1)[0])
        return sorted(names)

    def exists(self, rel):
        key = normalize_rel(rel)
        if key in self.files or key in self.errors:
            return True
        prefix = key.rstrip("/") + "/"
        return any(item.startswith(prefix) for item in self.files)


def normalize_rel(path):
    return str(path).replace("\\", "/").strip().strip("/")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_int(text, low=None, high=None):
    if text is None:
        return None
    try:
        value = int(str(text).strip(), 10)
    except (TypeError, ValueError):
        return None
    if low is not None and value < low:
        return None
    if high is not None and value > high:
        return None
    return value


def parse_float(text, low=None, high=None):
    if text is None:
        return None
    try:
        value = float(str(text).strip())
    except (TypeError, ValueError):
        return None
    if value != value or value in (float("inf"), float("-inf")):
        return None
    if low is not None and value < low:
        return None
    if high is not None and value > high:
        return None
    return value


def round1(value):
    return None if value is None else round(value + 0.0, 1)


def clean_label(text, fallback=""):
    value = str(text if text is not None else fallback)
    value = re.sub(r"[\x00-\x1f\x7f]", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    if not value:
        value = fallback
    return value[:48]


def is_cpu_chip(name):
    lowered = str(name or "").lower()
    return lowered in CPU_CHIP_NAMES or "cpu" in lowered or "soc" in lowered


def is_cpu_cooling(name):
    return str(name or "").lower() in CPU_COOLING_TYPES


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def discover_hwmon(reader):
    chips = []
    for entry in reader.listdir("class/hwmon"):
        if not HWMON_RE.match(entry):
            continue
        base = "class/hwmon/" + entry
        chip_name = clean_label(reader.read(base + "/name"), entry)
        readings = []
        for filename in reader.listdir(base):
            match = TEMP_INPUT_RE.match(filename)
            if not match:
                continue
            number = match.group(1)
            millidegrees = parse_int(
                reader.read(base + "/temp" + number + "_input"),
                TEMP_MIN_MC, TEMP_MAX_MC,
            )
            if millidegrees is None:
                continue
            label = clean_label(
                reader.read(base + "/temp" + number + "_label"),
                "temp" + number,
            )
            crit = parse_int(
                reader.read(base + "/temp" + number + "_crit"), 40000, 150000,
            )
            if crit is None:
                crit = parse_int(reader.read(base + "/temp1_crit"), 40000, 150000)
            readings.append({
                "label": label,
                "c": round1(millidegrees / 1000.0),
                "crit_c": round1(crit / 1000.0) if crit is not None else None,
            })
        fans = []
        for filename in reader.listdir(base):
            match = FAN_INPUT_RE.match(filename)
            if not match:
                continue
            number = match.group(1)
            rpm = parse_int(reader.read(base + "/fan" + number + "_input"), 0, 100000)
            if rpm is None:
                continue
            label = clean_label(
                reader.read(base + "/fan" + number + "_label"),
                "fan" + number,
            )
            fans.append({"label": label, "rpm": rpm})
        if readings or fans:
            chips.append({
                "name": chip_name,
                "dir": entry,
                "readings": readings,
                "fans": fans,
            })
    return chips


def discover_thermal_zones(reader):
    zones = []
    for entry in reader.listdir("class/thermal"):
        if not ZONE_RE.match(entry):
            continue
        base = "class/thermal/" + entry
        zone_type = clean_label(reader.read(base + "/type"), entry)
        millidegrees = parse_int(reader.read(base + "/temp"), TEMP_MIN_MC, TEMP_MAX_MC)
        if millidegrees is None:
            continue
        trip_c = None
        trips = []
        for filename in reader.listdir(base):
            match = re.match(r"^trip_point_(\d+)_temp$", filename)
            if not match:
                continue
            index = match.group(1)
            trip = parse_int(reader.read(base + "/" + filename), 40000, 150000)
            if trip is not None:
                trips.append((index, trip))
        for index, trip in sorted(trips):
            trip_type = clean_label(
                reader.read(base + "/trip_point_" + index + "_type"), "",
            ).lower()
            if "critical" in trip_type:
                trip_c = round1(trip / 1000.0)
                break
            if trip_c is None:
                trip_c = round1(trip / 1000.0)
        zones.append({
            "type": zone_type,
            "c": round1(millidegrees / 1000.0),
            "trip_c": trip_c,
        })
    return zones


def discover_cooling(reader):
    devices = []
    for entry in reader.listdir("class/thermal"):
        if not COOLING_RE.match(entry):
            continue
        base = "class/thermal/" + entry
        device_type = clean_label(reader.read(base + "/type"), entry)
        cur = parse_int(reader.read(base + "/cur_state"), 0, 100000)
        maximum = parse_int(reader.read(base + "/max_state"), 0, 100000)
        if cur is None and maximum is None:
            continue
        devices.append({
            "type": device_type,
            "cur": cur,
            "max": maximum,
            "cpu": is_cpu_cooling(device_type),
        })
    cpu_devices = [item for item in devices if item["cpu"]][:12]
    active = any(item["cur"] is not None and item["cur"] > 0 for item in cpu_devices)
    return {
        "available": bool(devices),
        "active": active,
        "devices": cpu_devices,
        "other_count": len(devices) - len(cpu_devices),
    }


def discover_cpufreq(reader):
    policies = []
    base_root = "devices/system/cpu/cpufreq"
    for entry in reader.listdir(base_root):
        if not POLICY_RE.match(entry):
            continue
        base = base_root + "/" + entry
        policies.append({
            "driver": clean_label(reader.read(base + "/scaling_driver"), ""),
            "governor": clean_label(reader.read(base + "/scaling_governor"), ""),
            "epp": clean_label(reader.read(base + "/energy_performance_preference"), ""),
            "cur": parse_int(reader.read(base + "/scaling_cur_freq"), 0, 20000000),
            "max": parse_int(reader.read(base + "/scaling_max_freq"), 0, 20000000),
            "cpuinfo": parse_int(reader.read(base + "/cpuinfo_max_freq"), 0, 20000000),
        })
    current = [item["cur"] for item in policies if item["cur"]]
    scaling_max = [item["max"] for item in policies if item["max"]]
    cpuinfo_max = [item["cpuinfo"] for item in policies if item["cpuinfo"]]
    drivers = sorted({item["driver"] for item in policies if item["driver"]})
    governors = sorted({item["governor"] for item in policies if item["governor"]})
    epps = sorted({item["epp"] for item in policies if item["epp"]})
    cap = min(scaling_max) if scaling_max else None
    ceiling = max(cpuinfo_max) if cpuinfo_max else None
    boost = parse_int(reader.read(base_root + "/boost"), 0, 1)
    return {
        "available": bool(policies),
        "policy_count": len(policies),
        "driver": ", ".join(drivers),
        "governor": ", ".join(governors),
        "epp": ", ".join(epps),
        "cur_min_mhz": round(min(current) / 1000) if current else None,
        "cur_max_mhz": round(max(current) / 1000) if current else None,
        "scaling_max_mhz": round(max(scaling_max) / 1000) if scaling_max else None,
        "cap_mhz": round(cap / 1000) if cap is not None else None,
        "cpuinfo_max_mhz": round(ceiling / 1000) if ceiling else None,
        "capped": bool(cap and ceiling and cap < ceiling - 1000),
        "boost": boost,
    }


def discover_pstate(reader):
    base = "devices/system/cpu/intel_pstate"
    status = clean_label(reader.read(base + "/status"), "")
    if not status:
        status = clean_label(reader.read("devices/system/cpu/amd_pstate/status"), "")
    kind = ""
    if reader.exists(base + "/status"):
        kind = "intel"
    elif reader.exists("devices/system/cpu/amd_pstate/status"):
        kind = "amd"
    if not kind:
        return {"kind": "", "status": "", "no_turbo": None, "turbo_pct": None,
                "max_perf_pct": None, "min_perf_pct": None,
                "hwp_dynamic_boost": None}
    root = base if kind == "intel" else "devices/system/cpu/amd_pstate"
    return {
        "kind": kind,
        "status": status,
        "no_turbo": parse_int(reader.read(root + "/no_turbo"), 0, 1),
        "turbo_pct": parse_int(reader.read(root + "/turbo_pct"), 0, 100),
        "max_perf_pct": parse_int(reader.read(root + "/max_perf_pct"), 0, 100),
        "min_perf_pct": parse_int(reader.read(root + "/min_perf_pct"), 0, 100),
        "hwp_dynamic_boost": parse_int(reader.read(root + "/hwp_dynamic_boost"), 0, 1),
    }


def discover_throttle(reader):
    core_count = 0
    package_count = 0
    core_total = 0
    package_total = 0
    core_max = 0
    package_max = 0
    supported = False
    cpu_count = 0
    for entry in reader.listdir("devices/system/cpu"):
        if not CPU_RE.match(entry):
            continue
        base = "devices/system/cpu/" + entry + "/thermal_throttle"
        values = {
            "core_count": parse_int(reader.read(base + "/core_throttle_count"), 0, 10 ** 12),
            "package_count": parse_int(reader.read(base + "/package_throttle_count"), 0, 10 ** 12),
            "core_total": parse_int(reader.read(base + "/core_throttle_total_time_ms"), 0, 10 ** 15),
            "package_total": parse_int(reader.read(base + "/package_throttle_total_time_ms"), 0, 10 ** 15),
            "core_max": parse_int(reader.read(base + "/core_throttle_max_time_ms"), 0, 10 ** 15),
            "package_max": parse_int(reader.read(base + "/package_throttle_max_time_ms"), 0, 10 ** 15),
        }
        if any(value is not None for value in values.values()):
            supported = True
        cpu_count += 1
        core_count += values["core_count"] or 0
        package_count = max(package_count, values["package_count"] or 0)
        core_total += values["core_total"] or 0
        package_total = max(package_total, values["package_total"] or 0)
        core_max = max(core_max, values["core_max"] or 0)
        package_max = max(package_max, values["package_max"] or 0)
    return {
        "supported": supported,
        "cpu_count": cpu_count,
        "core_count": core_count,
        "package_count": package_count,
        "core_total_ms": core_total,
        "package_total_ms": package_total,
        "core_max_ms": core_max,
        "package_max_ms": package_max,
    }


def discover_power_limits(reader):
    limits = []
    entries = reader.listdir("class/powercap")
    # Both intel-rapl (MSR) and intel-rapl-mmio can describe package-0. Prefer
    # the MSR view, which matches the limits tools such as powercap-utils use.
    entries.sort(key=lambda item: (1 if "mmio" in item else 0, item))
    seen = set()
    for entry in entries:
        if not (entry.startswith("intel-rapl") or entry.startswith("amd-rapl")):
            continue
        base = "class/powercap/" + entry
        domain = clean_label(reader.read(base + "/name"), entry)
        for filename in reader.listdir(base):
            match = CONSTRAINT_RE.match(filename)
            if not match:
                continue
            number = match.group(1)
            microwatts = parse_int(
                reader.read(base + "/constraint_" + number + "_power_limit_uw"),
                0, 2000000000,
            )
            if microwatts is None or microwatts <= 0:
                continue
            watts = microwatts / 1000000.0
            if watts > 1000:
                continue
            max_uw = parse_int(
                reader.read(base + "/constraint_" + number + "_max_power_uw"),
                0, 2000000000,
            )
            constraint = clean_label(
                reader.read(base + "/constraint_" + number + "_name"),
                "constraint " + number,
            )
            key = (domain.lower(), constraint.lower())
            if key in seen:
                continue
            seen.add(key)
            limits.append({
                "domain": domain,
                "constraint": constraint,
                "watts": round1(watts),
                "max_watts": round1(max_uw / 1000000.0) if max_uw else None,
            })
    return limits[:MAX_POWER_LIMITS]


def battery_energy_wh(base, reader, voltage_uv):
    energy_uw = parse_int(reader.read(base + "/energy_now"), 0, 10 ** 12)
    if energy_uw is not None:
        return round(energy_uw / 1000000.0, 3)
    charge_uah = parse_int(reader.read(base + "/charge_now"), 0, 10 ** 12)
    if charge_uah is not None and voltage_uv:
        return round((charge_uah * voltage_uv) / 10 ** 12, 3)
    return None


def battery_full_wh(base, reader, voltage_uv):
    energy_uw = parse_int(reader.read(base + "/energy_full"), 0, 10 ** 12)
    if energy_uw is not None:
        return round(energy_uw / 1000000.0, 3)
    charge_uah = parse_int(reader.read(base + "/charge_full"), 0, 10 ** 12)
    if charge_uah is not None and voltage_uv:
        return round((charge_uah * voltage_uv) / 10 ** 12, 3)
    return None


def discover_battery(reader):
    batteries = []
    ac_name = ""
    ac_known = False
    ac_online = False
    for entry in reader.listdir("class/power_supply"):
        base = "class/power_supply/" + entry
        supply_type = clean_label(reader.read(base + "/type"), "")
        if supply_type == "Battery":
            present = parse_int(reader.read(base + "/present"), 0, 1)
            if present == 0:
                continue
            scope = clean_label(reader.read(base + "/scope"), "")
            if scope and scope.lower() == "device":
                continue
            batteries.append((entry, base))
        elif supply_type in ("Mains", "USB", "USB_C", "USB_PD", "Wireless"):
            online = parse_int(reader.read(base + "/online"), 0, 1)
            if online is not None:
                ac_known = True
                if online > 0:
                    ac_online = True
                    ac_name = entry

    if not batteries:
        return {
            "present": False, "name": "", "count": 0, "status": "", "percent": None,
            "energy_wh": None, "energy_full_wh": None, "charge_ah": None,
            "charge_full_ah": None, "voltage_v": None, "cycle_count": None,
            "power_w": None, "power_source": "", "power_direction": "",
            "ac_online": ac_online, "ac_known": ac_known, "ac_name": ac_name,
        }

    batteries.sort(key=lambda item: (0 if item[0].upper().startswith("BAT") else 1, item[0]))
    name, base = batteries[0]
    status = clean_label(reader.read(base + "/status"), "Unknown")
    capacity = parse_int(reader.read(base + "/capacity"), 0, 100)
    voltage_uv = parse_int(reader.read(base + "/voltage_now"), 0, 100000000)
    cycle_count = parse_int(reader.read(base + "/cycle_count"), 0, 100000)
    energy_wh = battery_energy_wh(base, reader, voltage_uv)
    energy_full_wh = battery_full_wh(base, reader, voltage_uv)
    charge_uah = parse_int(reader.read(base + "/charge_now"), 0, 10 ** 12)
    charge_full_uah = parse_int(reader.read(base + "/charge_full"), 0, 10 ** 12)

    power_w = None
    power_source = ""
    power_uw = parse_int(reader.read(base + "/power_now"), 0, 10 ** 9)
    if power_uw is not None:
        power_w = round(power_uw / 1000000.0, 3)
        power_source = "sysfs:power_now"
    else:
        current_ua = parse_int(reader.read(base + "/current_now"), 0, 10 ** 9)
        if current_ua is not None and voltage_uv:
            power_w = round((current_ua * voltage_uv) / 10 ** 12, 3)
            power_source = "sysfs:current_voltage"
    if power_w is not None and power_w > 1000:
        power_w = None
        power_source = ""

    if capacity is None and energy_wh is not None and energy_full_wh:
        capacity = max(0, min(100, round(energy_wh / energy_full_wh * 100)))

    return {
        "present": True,
        "name": clean_label(name, "BAT0"),
        "count": len(batteries),
        "status": status,
        "percent": capacity,
        "energy_wh": energy_wh,
        "energy_full_wh": energy_full_wh,
        "charge_ah": round(charge_uah / 1000000.0, 3) if charge_uah is not None else None,
        "charge_full_ah": round(charge_full_uah / 1000000.0, 3) if charge_full_uah is not None else None,
        "voltage_v": round(voltage_uv / 1000000.0, 3) if voltage_uv is not None else None,
        "cycle_count": cycle_count,
        "power_w": power_w,
        "power_source": power_source,
        "power_direction": "in" if status.lower() == "charging" else (
            "out" if status.lower() == "discharging" else ""
        ),
        "ac_online": ac_online,
        "ac_known": ac_known,
        "ac_name": ac_name,
    }


# ---------------------------------------------------------------------------
# CPU selection
# ---------------------------------------------------------------------------

def choose_cpu(chips, zones):
    zone_types = {str(zone.get("type", "")).lower() for zone in zones}
    best_chip = None
    for chip in chips:
        if is_cpu_chip(chip["name"]) and chip["readings"]:
            if best_chip is None:
                best_chip = chip
            else:
                # Prefer the chip whose package label is most explicit.
                def rank(candidate):
                    name = candidate["name"].lower()
                    if name in ("coretemp", "k10temp", "zenpower"):
                        return 0
                    if name in ("cpu_thermal", "soc_thermal"):
                        return 1
                    return 2
                if rank(chip) < rank(best_chip):
                    best_chip = chip

    package = None
    package_source = ""
    chosen_chip = None
    if best_chip is not None:
        ranked = []
        for reading in best_chip["readings"]:
            lowered = reading["label"].lower()
            priority = 99
            for index, hint in enumerate(PACKAGE_LABEL_HINTS):
                if hint in lowered:
                    priority = index
                    break
            if priority < 99:
                ranked.append((priority, -reading["c"], reading))
        if ranked:
            ranked.sort(key=lambda item: (item[0], item[1]))
            package = ranked[0][2]
            package_source = "hwmon:" + best_chip["name"]
            chosen_chip = best_chip

    if package is None:
        zone_candidates = []
        for zone in zones:
            lowered = zone["type"].lower()
            if lowered in ZONE_PRIORITY:
                zone_candidates.append((ZONE_PRIORITY[lowered], -zone["c"], zone))
            elif "cpu" in lowered or "soc" in lowered or "package" in lowered:
                zone_candidates.append((3, -zone["c"], zone))
        if zone_candidates:
            zone_candidates.sort(key=lambda item: (item[0], item[1]))
            selected = zone_candidates[0][2]
            package = {"label": selected["type"], "c": selected["c"],
                       "crit_c": selected["trip_c"]}
            package_source = "thermal:" + selected["type"]
            chosen_chip = best_chip

    if package is None and best_chip is not None:
        hottest = max(best_chip["readings"], key=lambda item: item["c"])
        package = hottest
        package_source = "hwmon:" + best_chip["name"]
        chosen_chip = best_chip

    if package is None and zones:
        hottest = max(zones, key=lambda item: item["c"])
        package = {"label": hottest["type"], "c": hottest["c"],
                   "crit_c": hottest["trip_c"]}
        package_source = "thermal:" + hottest["type"]

    cores = []
    sensors = []
    if chosen_chip is not None:
        for reading in chosen_chip["readings"]:
            if package is not None and reading is package:
                continue
            lowered = reading["label"].lower()
            if "core" in lowered or "tdie" in lowered or "tctl" in lowered:
                cores.append({"label": reading["label"], "c": reading["c"]})
        cores = cores[:MAX_CORES]
        for chip in chips:
            if chip is chosen_chip:
                continue
            if chip["name"].lower() in zone_types:
                continue
            for reading in chip["readings"]:
                sensors.append({
                    "chip": chip["name"], "label": reading["label"],
                    "c": reading["c"], "crit_c": reading["crit_c"],
                    "source": "hwmon",
                })
    else:
        for chip in chips:
            if chip["name"].lower() in zone_types:
                continue
            for reading in chip["readings"]:
                sensors.append({
                    "chip": chip["name"], "label": reading["label"],
                    "c": reading["c"], "crit_c": reading["crit_c"],
                    "source": "hwmon",
                })

    for zone in zones:
        if package_source == "thermal:" + zone["type"]:
            continue
        sensors.append({
            "chip": zone["type"], "label": zone["type"], "c": zone["c"],
            "crit_c": zone["trip_c"], "source": "thermal",
        })

    seen = set()
    deduped = []
    for sensor in sorted(sensors, key=lambda item: (item["chip"].lower(), item["label"].lower())):
        key = (sensor["chip"].lower(), sensor["label"].lower(), sensor["c"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(sensor)
        if len(deduped) >= MAX_SENSORS:
            break

    available = package is not None
    return {
        "available": available,
        "package_c": package["c"] if package else None,
        "package_label": clean_label(package["label"], "CPU") if package else "",
        "package_source": package_source,
        "crit_c": package.get("crit_c") if package else None,
        "cores": cores,
        "sensors": deduped,
        "max_c": max([package["c"]] + [core["c"] for core in cores]) if package else None,
    }


# ---------------------------------------------------------------------------
# Document assembly
# ---------------------------------------------------------------------------

def collect(reader):
    chips = discover_hwmon(reader)
    zones = discover_thermal_zones(reader)
    cpu = choose_cpu(chips, zones)
    cooling = discover_cooling(reader)
    throttle = discover_throttle(reader)
    freq = discover_cpufreq(reader)
    pstate = discover_pstate(reader)
    power_limits = discover_power_limits(reader)
    battery = discover_battery(reader)
    fans = []
    for chip in chips:
        for fan in chip["fans"]:
            fans.append({
                "chip": chip["name"],
                "label": fan["label"],
                "rpm": fan["rpm"],
            })
    fans = fans[:8]

    warnings = []
    if not cpu["available"]:
        warnings.append("No CPU temperature sensor found.")
    if not battery["present"]:
        warnings.append("No battery exposed by /sys/class/power_supply.")
    elif battery["power_w"] is None:
        warnings.append("Battery power is not exposed (power_now/current_now unreadable).")
    if not fans:
        warnings.append("No fan RPM sensor exposed.")
    if not throttle["supported"]:
        warnings.append("Thermal throttle counters are not exposed.")

    return {
        "schema": SCHEMA_VERSION,
        "generated_at": time.time(),
        "mock": None,
        "cpu": cpu,
        "fans": fans,
        "cooling": cooling,
        "throttle": throttle,
        "freq": freq,
        "pstate": pstate,
        "power_limits": power_limits,
        "battery": battery,
        "warnings": warnings,
    }


def empty_document():
    return {
        "schema": SCHEMA_VERSION,
        "generated_at": time.time(),
        "mock": None,
        "cpu": {
            "available": False, "package_c": None, "package_label": "",
            "package_source": "", "crit_c": None, "cores": [], "sensors": [],
            "max_c": None,
        },
        "fans": [],
        "cooling": {"available": False, "active": False, "devices": [], "other_count": 0},
        "throttle": {
            "supported": False, "cpu_count": 0, "core_count": 0, "package_count": 0,
            "core_total_ms": 0, "package_total_ms": 0, "core_max_ms": 0,
            "package_max_ms": 0,
        },
        "freq": {
            "available": False, "policy_count": 0, "driver": "", "governor": "",
            "epp": "", "cur_min_mhz": None, "cur_max_mhz": None,
            "scaling_max_mhz": None, "cap_mhz": None, "cpuinfo_max_mhz": None,
            "capped": False, "boost": None,
        },
        "pstate": {
            "kind": "", "status": "", "no_turbo": None, "turbo_pct": None,
            "max_perf_pct": None, "min_perf_pct": None, "hwp_dynamic_boost": None,
        },
        "power_limits": [],
        "battery": {
            "present": False, "name": "", "count": 0, "status": "", "percent": None,
            "energy_wh": None, "energy_full_wh": None, "charge_ah": None,
            "charge_full_ah": None, "voltage_v": None, "cycle_count": None,
            "power_w": None, "power_source": "", "power_direction": "",
            "ac_online": False, "ac_known": False, "ac_name": "",
        },
        "warnings": [],
    }


# ---------------------------------------------------------------------------
# Mock scenarios
# ---------------------------------------------------------------------------

def mock_directory():
    return Path(__file__).resolve().parent.parent / "mock"


def load_scenario(name):
    if not MOCK_NAME_RE.match(str(name or "")):
        raise ValueError("invalid mock scenario name")
    root = mock_directory().resolve()
    return _load_scenario(name, root, [])


def _load_scenario(name, root, stack):
    if name in stack:
        raise ValueError("mock scenario base cycle: " + name)
    path = (root / name / "scenario.json").resolve()
    root_text = str(root) + os.sep
    if not str(path).startswith(root_text) or not path.is_file():
        raise ValueError("unknown mock scenario: " + name)
    if path.stat().st_size > 512 * 1024:
        raise ValueError("mock scenario is too large")
    with path.open("r", encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, dict):
        raise ValueError("mock scenario must be an object")

    result = {
        "files": {}, "errors": {},
        "description": clean_label(raw.get("description"), ""),
        "profile": None, "upower": None, "history_c": None,
        "throttle_delta": None,
    }
    base = raw.get("base")
    if base is not None:
        inherited = _load_scenario(str(base), root, stack + [name])
        result["files"].update(inherited["files"])
        result["errors"].update(inherited["errors"])
        for key in ("description", "profile", "upower", "history_c", "throttle_delta"):
            if inherited.get(key) is not None:
                result[key] = inherited[key]

    files = raw.get("files") or {}
    errors = raw.get("errors") or {}
    if not isinstance(files, dict) or not isinstance(errors, dict):
        raise ValueError("mock files/errors must be objects")
    for key, value in files.items():
        relative = normalize_rel(key)
        if not relative or any(part == ".." for part in relative.split("/")):
            raise ValueError("invalid mock file path")
        result["files"][relative] = "" if value is None else str(value)
    for key, value in errors.items():
        relative = normalize_rel(key)
        if not relative or any(part == ".." for part in relative.split("/")):
            raise ValueError("invalid mock error path")
        result["errors"][relative] = str(value)

    for key in ("remove",):
        for item in raw.get(key) or []:
            relative = normalize_rel(item)
            result["files"].pop(relative, None)
            result["errors"].pop(relative, None)

    for key in ("description", "profile", "upower", "history_c", "throttle_delta"):
        if key in raw:
            result[key] = raw[key]
    return result


def mock_aux(scenario, name):
    profile = scenario.get("profile")
    if not isinstance(profile, dict):
        profile = {
            "available": True, "active": "balanced",
            "profiles": ["power-saver", "balanced", "performance"],
            "readonly_reason": "",
        }
    upower = scenario.get("upower")
    if upower is not None and not isinstance(upower, dict):
        upower = None
    history = scenario.get("history_c")
    if not isinstance(history, list):
        history = None
    delta = scenario.get("throttle_delta")
    if not isinstance(delta, dict):
        delta = None
    return {
        "scenario": name,
        "description": scenario.get("description") or "",
        "profile": profile,
        "upower": upower,
        "history_c": history,
        "throttle_delta": delta,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_cli(argv):
    """Tiny argument parser. argparse costs ~30 ms of import time per sample."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    mock = ""
    while arguments:
        argument = arguments.pop(0)
        if argument in ("-h", "--help"):
            sys.stdout.write(
                "usage: thermal_power.py [--mock SCENARIO]\n"
                "Read-only thermal, power and battery collector.\n"
            )
            return None
        if argument == "--mock":
            if not arguments:
                raise ValueError("--mock needs a scenario name")
            mock = arguments.pop(0)
        elif argument.startswith("--mock="):
            mock = argument.split("=", 1)[1]
        else:
            raise ValueError("unknown argument: " + argument)
    return mock


def main(argv=None):
    try:
        mock_name = parse_cli(argv)
    except ValueError as exc:
        sys.stderr.write("thermal-power: %s\n" % exc)
        return 2
    if mock_name is None:
        return 0

    scenario = None
    if mock_name:
        try:
            scenario = load_scenario(mock_name)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            sys.stderr.write("thermal-power: %s\n" % exc)
            return 2
        reader = MockReader(scenario["files"], scenario["errors"])
    else:
        reader = Reader("/sys")

    try:
        document = collect(reader)
    except Exception as exc:  # Never let a surprising sysfs shape break the bar.
        document = empty_document()
        document["warnings"].append("Internal collector error: " + exc.__class__.__name__)

    if scenario is not None:
        document["mock"] = mock_name
        document["mock_aux"] = mock_aux(scenario, mock_name)

    try:
        sys.stdout.write(json.dumps(document, separators=(",", ":"),
                                    ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

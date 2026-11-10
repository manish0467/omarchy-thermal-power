#!/usr/bin/env python3
"""Unit and fixture tests for helper/thermal_power.py.

Run with any Python 3.9+ interpreter:
    python3 -I tests/test_helper.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "helper" / "thermal_power.py"
sys.path.insert(0, str(HELPER.parent))

import thermal_power as helper  # noqa: E402


def write_tree(root, files):
    for relative, value in files.items():
        path = Path(root) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(value), encoding="utf-8")


class ParsingTests(unittest.TestCase):
    def test_parse_int_and_float_ranges(self):
        self.assertEqual(helper.parse_int(" 47000 ", 0, 100000), 47000)
        self.assertIsNone(helper.parse_int("47000", 50000, 100000))
        self.assertIsNone(helper.parse_int("nope"))
        self.assertIsNone(helper.parse_int(None))
        self.assertEqual(helper.parse_float("24.4", 0, 100), 24.4)
        self.assertIsNone(helper.parse_float("nan"))
        self.assertIsNone(helper.parse_float("1e999"))
        self.assertEqual(helper.clean_label("  Core\x00 0\n"), "Core 0")

    def test_reader_refuses_parent_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = helper.Reader(directory)
            self.assertIsNone(reader.read("../etc/passwd"))
            self.assertEqual(reader.listdir("../../"), [])


class CollectionTests(unittest.TestCase):
    def test_cpu_selection_battery_and_ac(self):
        files = {
            "class/hwmon/hwmon0/name": "coretemp",
            "class/hwmon/hwmon0/temp1_input": "46000",
            "class/hwmon/hwmon0/temp1_label": "Package id 0",
            "class/hwmon/hwmon0/temp1_crit": "100000",
            "class/hwmon/hwmon0/temp2_input": "44000",
            "class/hwmon/hwmon0/temp2_label": "Core 0",
            "class/hwmon/hwmon0/temp3_input": "47000",
            "class/hwmon/hwmon0/temp3_label": "Core 1",
            "class/hwmon/hwmon1/name": "nvme",
            "class/hwmon/hwmon1/temp1_input": "40850",
            "class/hwmon/hwmon1/temp1_label": "Composite",
            "class/hwmon/hwmon2/name": "thinkpad",
            "class/hwmon/hwmon2/fan1_input": "2840",
            "class/hwmon/hwmon2/fan1_label": "fan1",
            "class/power_supply/ADP1/type": "Mains",
            "class/power_supply/ADP1/online": "0",
            "class/power_supply/BAT0/type": "Battery",
            "class/power_supply/BAT0/present": "1",
            "class/power_supply/BAT0/status": "Discharging",
            "class/power_supply/BAT0/capacity": "62",
            "class/power_supply/BAT0/energy_now": "21200000",
            "class/power_supply/BAT0/energy_full": "34564000",
            "class/power_supply/BAT0/power_now": "8200000",
            "class/power_supply/BAT0/voltage_now": "12300000",
            "class/power_supply/BAT0/cycle_count": "229",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            document = helper.collect(helper.Reader(directory))
        self.assertEqual(document["cpu"]["package_c"], 46.0)
        self.assertEqual(document["cpu"]["package_source"], "hwmon:coretemp")
        self.assertEqual(len(document["cpu"]["cores"]), 2)
        self.assertEqual(document["cpu"]["sensors"][0]["chip"], "nvme")
        self.assertEqual(document["fans"][0]["rpm"], 2840)
        self.assertEqual(document["battery"]["power_w"], 8.2)
        self.assertEqual(document["battery"]["power_source"], "sysfs:power_now")
        self.assertFalse(document["battery"]["ac_online"])
        self.assertTrue(document["battery"]["ac_known"])
        self.assertEqual(document["battery"]["cycle_count"], 229)

    def test_battery_current_voltage_fallback(self):
        files = {
            "class/power_supply/BAT0/type": "Battery",
            "class/power_supply/BAT0/status": "Discharging",
            "class/power_supply/BAT0/capacity": "50",
            "class/power_supply/BAT0/current_now": "650000",
            "class/power_supply/BAT0/voltage_now": "12000000",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            battery = helper.discover_battery(helper.Reader(directory))
        self.assertEqual(battery["power_w"], 7.8)
        self.assertEqual(battery["power_source"], "sysfs:current_voltage")

    def test_missing_battery_power_is_reported_not_invented(self):
        files = {
            "class/power_supply/BAT0/type": "Battery",
            "class/power_supply/BAT0/status": "Discharging",
            "class/power_supply/BAT0/capacity": "50",
            "class/power_supply/BAT0/energy_now": "17000000",
            "class/power_supply/BAT0/energy_full": "34000000",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            document = helper.collect(helper.Reader(directory))
        self.assertIsNone(document["battery"]["power_w"])
        self.assertTrue(any("Battery power" in item for item in document["warnings"]))

    def test_zero_battery_power_is_not_a_missing_sensor_warning(self):
        files = {
            "class/power_supply/BAT0/type": "Battery",
            "class/power_supply/BAT0/status": "Full",
            "class/power_supply/BAT0/capacity": "100",
            "class/power_supply/BAT0/power_now": "0",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            document = helper.collect(helper.Reader(directory))
        self.assertEqual(document["battery"]["power_w"], 0.0)
        self.assertFalse(any("Battery power" in item for item in document["warnings"]))

    def test_throttling_and_cooling_evidence(self):
        files = {
            "class/thermal/cooling_device0/type": "Processor",
            "class/thermal/cooling_device0/cur_state": "3",
            "class/thermal/cooling_device0/max_state": "10",
            "class/thermal/cooling_device1/type": "intel_powerclamp",
            "class/thermal/cooling_device1/cur_state": "0",
            "class/thermal/cooling_device1/max_state": "100",
            "devices/system/cpu/cpu0/thermal_throttle/core_throttle_count": "2",
            "devices/system/cpu/cpu0/thermal_throttle/package_throttle_count": "1",
            "devices/system/cpu/cpu1/thermal_throttle/core_throttle_count": "3",
            "devices/system/cpu/cpu1/thermal_throttle/package_throttle_count": "1",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            document = helper.collect(helper.Reader(directory))
        self.assertTrue(document["cooling"]["active"])
        self.assertEqual(document["throttle"]["core_count"], 5)
        self.assertEqual(document["throttle"]["package_count"], 1)
        self.assertTrue(document["throttle"]["supported"])

    def test_powercap_prefers_msr_and_deduplicates_mmio(self):
        files = {
            "class/powercap/intel-rapl:0/name": "package-0",
            "class/powercap/intel-rapl:0/constraint_0_name": "long_term",
            "class/powercap/intel-rapl:0/constraint_0_power_limit_uw": "19000000",
            "class/powercap/intel-rapl:0/constraint_0_max_power_uw": "28000000",
            "class/powercap/intel-rapl-mmio:0/name": "package-0",
            "class/powercap/intel-rapl-mmio:0/constraint_0_name": "long_term",
            "class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw": "21000000",
        }
        with tempfile.TemporaryDirectory() as directory:
            write_tree(directory, files)
            limits = helper.discover_power_limits(helper.Reader(directory))
        self.assertEqual(len(limits), 1)
        self.assertEqual(limits[0]["watts"], 19.0)

    def test_no_sensors_still_returns_battery_and_profile_aux(self):
        document = helper.collect(helper.MockReader({}))
        self.assertFalse(document["cpu"]["available"])
        self.assertFalse(document["battery"]["present"])
        self.assertTrue(any("No CPU temperature" in item for item in document["warnings"]))


class MockScenarioTests(unittest.TestCase):
    def load(self, name):
        scenario = helper.load_scenario(name)
        reader = helper.MockReader(scenario["files"], scenario["errors"])
        document = helper.collect(reader)
        document["mock"] = name
        document["mock_aux"] = helper.mock_aux(scenario, name)
        return document

    def test_mock_names_are_safe(self):
        for name in ["../normal", "normal/../warm", "", "Normal", "preview;rm"]:
            with self.assertRaises(ValueError):
                helper.load_scenario(name)

    def test_unknown_mock_base_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bad").mkdir()
            (root / "bad" / "scenario.json").write_text(
                '{"base": "missing"}', encoding="utf-8")
            with self.assertRaises(ValueError):
                helper._load_scenario("bad", root, [])

    def test_normal(self):
        document = self.load("normal")
        self.assertEqual(document["cpu"]["package_c"], 45.0)
        self.assertIsNone(document["battery"]["power_w"])
        self.assertEqual(document["mock_aux"]["profile"]["active"], "balanced")
        self.assertEqual(document["mock_aux"]["upower"]["changeRate"], 9.8)

    def test_warm_hot_and_throttling(self):
        self.assertEqual(self.load("warm")["cpu"]["package_c"], 82.0)
        self.assertEqual(self.load("hot")["cpu"]["package_c"], 93.0)
        throttling = self.load("throttling")
        self.assertTrue(throttling["cooling"]["active"])
        self.assertGreater(throttling["throttle"]["core_count"], 0)
        self.assertEqual(throttling["mock_aux"]["throttle_delta"]["core"], 1)

    def test_degraded_fixtures(self):
        self.assertFalse(self.load("no-battery")["battery"]["present"])
        self.assertFalse(self.load("no-sensors")["cpu"]["available"])
        profile = self.load("profile-daemon-missing")["mock_aux"]["profile"]
        self.assertFalse(profile["available"])
        self.assertIn("not running", profile["readonly_reason"])
        charging = self.load("on-ac-charging")
        self.assertEqual(charging["battery"]["status"], "Charging")
        self.assertTrue(charging["battery"]["ac_online"])
        self.assertEqual(charging["mock_aux"]["upower"]["changeRate"], 24.4)

    def test_preview(self):
        document = self.load("preview")
        self.assertEqual(document["cpu"]["package_c"], 48.0)
        self.assertEqual(document["battery"]["percent"], 68)
        self.assertEqual(len(document["mock_aux"]["history_c"]), 40)

    def test_all_scenarios_have_schema_one_and_aux(self):
        for directory in sorted((ROOT / "mock").iterdir()):
            if not directory.is_dir():
                continue
            document = self.load(directory.name)
            self.assertEqual(document["schema"], 1, directory.name)
            self.assertEqual(document["mock"], directory.name)
            self.assertIn("profile", document["mock_aux"], directory.name)


class CliTests(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(HELPER)] + list(args),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=30,
        )

    def test_mock_cli_is_valid_json_and_clean_stderr(self):
        result = self.run_helper("--mock", "preview")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        document = json.loads(result.stdout)
        self.assertEqual(document["schema"], 1)
        self.assertEqual(document["mock"], "preview")
        self.assertEqual(document["cpu"]["package_c"], 48.0)

    def test_invalid_mock_exits_two_without_traceback(self):
        result = self.run_helper("--mock", "../normal")
        self.assertEqual(result.returncode, 2)
        self.assertIn("mock scenario", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_real_cli_is_valid_json(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["schema"], 1)
        self.assertIn("cpu", document)
        self.assertIn("battery", document)


class SecurityTests(unittest.TestCase):
    def test_helper_has_no_privilege_escalation_or_network(self):
        text = (ROOT / "helper" / "thermal_power.py").read_text(encoding="utf-8")
        for banned in ["import subprocess", "os.system", "pkexec", "sudo ",
                       "urllib", "http://", "https://", "socket."]:
            self.assertNotIn(banned, text)

    def test_qml_has_no_shell_interpolation_from_sensor_text(self):
        text = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        self.assertIn('"omarchy-powerprofiles-set", "autodetect", name', text)
        self.assertNotIn("/bin/sh", text)
        self.assertNotIn('"sudo"', text)
        self.assertNotIn('"pkexec"', text)
        self.assertNotIn('"bash"', text)

    def test_system_profile_names_are_allow_listed(self):
        text = (ROOT / "Model.js").read_text(encoding="utf-8")
        self.assertIn('PROFILE_NAMES = ["power-saver", "balanced", "performance"]', text)


if __name__ == "__main__":
    unittest.main(verbosity=2)

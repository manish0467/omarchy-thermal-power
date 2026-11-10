# Test plan

This plan covers the automated suite, visual mock checks, passive live checks, and the one narrowly
scoped profile-switch test. It deliberately excludes hardware stress/load tests, SMART reads, fan
control, performance-profile switching, and any root operation.

## Automated tests

Run from the repository root:

```bash
node tests/test_model.js
python3 -I tests/test_helper.py
python3 -I tests/stress_helper.py --runs 320
```

Expected:

- `tests/test_model.js`: 17 tests pass. Covers formatting, state classification, profile
  allow-listing and glyphs, history windowing, smoothing, battery merge, and notification sustain /
  cooldown logic.
- `tests/test_helper.py`: 22 tests pass. Covers sysfs normalization, package selection, fan/cooling
  handling, throttle counters, powercap limits, battery current/voltage fallback, missing values,
  mock scenarios, path safety, and CLI behavior.
- `tests/stress_helper.py`: at least 300 runs, all exit code 0, empty stderr, valid schema-1 JSON.
  The loop invokes the same `python3 -I helper/thermal_power.py` argv used by the shell.

Test both interpreters when available. If Python 3.9 is installed outside `PATH` (for example by `uv`), substitute its full path:

```bash
python3 -I tests/test_helper.py
python3.9 -I tests/test_helper.py
python3 -I tests/stress_helper.py --runs 320
python3.9 -I tests/stress_helper.py --runs 320
```

The Python 3.14 / PyGObject shutdown race does not apply to this stdlib-only helper, but the loop is
kept to catch any new interpreter-shutdown stderr or non-JSON output.

Validate the plugin folder (not a symlink) and syntax-check QML:

```bash
omarchy plugin validate .
qmllint BarWidget.qml Panel.qml
```

`qmllint` may warn about Omarchy/Quickshell style properties it cannot resolve outside the shell
import path; syntax errors must be absent.

## Mock visual matrix

Set the development-only `mockScenario` setting to each fixture, close and reopen the panel, and
check both bar and panel. Fixtures never read real sysfs.

| Fixture | Expected bar | Expected panel |
| --- | --- | --- |
| `normal` | `45° 9.8W↓`-style label, thermometer | Normal state, CPU/battery details |
| `warm` | Amber temperature and thermometer | Warm state pill, amber hero |
| `hot` | Red temperature and thermometer | Hot state pill, urgent red |
| `throttling` | Red temperature and triangle | Throttling evidence, event row |
| `no-battery` | Temperature only | Battery “Not exposed”, AC state |
| `no-sensors` | `--` plus battery/AC and question glyph | “No CPU temperature sensor” |
| `profile-daemon-missing` | Normal data if temp exists | No active switch; reason shown |
| `on-ac-charging` | `24W↑` (charging input) | Charging direction and charger-input note |
| `preview` | Stable seeded history | Seeded sparkline, screenshots |

For each state:

1. Open the panel with the widget/button or the plugin IPC target.
2. Confirm the header state, bar color/glyph, and unavailable text agree.
3. Scroll through the full panel and expand **Other sensors**.
4. Confirm no QML `ReferenceError`, `TypeError`, binding-loop or helper errors appear:

   ```bash
   qs log -p /usr/share/omarchy/shell --tail 100
   ```

5. Confirm profile buttons show leaf / balance / speedometer glyphs (not fallback glyphs), and that
   the active profile is highlighted.
6. Click the refresh button and verify the update timestamp changes.
7. Confirm the scrollbar appears when content exceeds the panel height and the panel resets to the
   top when reopened.

## Passive live test

Use the real widget with the plugin enabled and `mockScenario` empty.

- Bar updates while closed at the configured 10 s interval.
- Bar label shows a real package temperature and battery watts/AC.
- Open panel and verify:
  - package source (`hwmon:coretemp` or thermal zone) is named;
  - per-core values are present when exposed;
  - `Other sensors` includes NVMe/ACPI values and is collapsed by default;
  - fan section says “No fan RPM sensor exposed” on hardware without fan sensors;
  - throttle section says counters are exposed and explains zero-counter limits;
  - power limits show readable PL1/PL2/peak values, with no RAPL energy use;
  - battery source note names UPower fallback when sysfs power is missing;
  - profile daemon check shows PPD active and no conflicting manager.
- Leave the panel closed for several minutes and verify no helper error appears and CPU/temperature
  values remain plausible.
- Confirm no plugin state directory is created. The expected preference files are only touched by an
  explicit profile click.

### Helper CPU-cost measurement

Run a short loop and record elapsed and per-process CPU time:

```bash
cd ~/omarchy-thermal-power
/usr/bin/time -f 'elapsed=%e user=%U sys=%S maxrss_kb=%M' \
  sh -c 'for i in $(seq 1 20); do python3 -I helper/thermal_power.py >/dev/null; done'
```

Expected order of magnitude on the test machine: about 0.1 s per invocation, so closed-panel polling
at 10 s is about 1% of one core, and open-panel polling at 2 s is about 5–6% of one core. There is no
persistent process. Record the measured numbers and note that they are machine-specific.

## Profile switching test

Only test `power-saver` ↔ `balanced`. Do not select `performance`. Restore the original profile and
preference files afterwards.

1. Record the current state:

   ```bash
   busctl --json=short get-property org.freedesktop.UPower.PowerProfiles \
     /org/freedesktop/UPower/PowerProfiles \
     org.freedesktop.UPower.PowerProfiles ActiveProfile
   cat ~/.local/state/omarchy/powerprofiles/ac
   cat ~/.local/state/omarchy/powerprofiles/battery
   ```

2. Confirm the panel shows the same active profile and that the profile buttons are enabled only when
   PPD is active and no conflicting manager is present.
3. Switch to `balanced` in the panel. Verify:
   - the active profile changes to Balanced;
   - the preference files contain the chosen profile for the current power source;
   - no `sudo`, `pkexec`, polkit prompt or password appears;
   - the bar optional profile glyph, if enabled, matches the new profile.
4. Switch back to the original `power-saver` profile and verify the preference files are restored.
5. If the test cannot restore the original values, stop and report; do not leave a changed profile.

The plugin uses exactly `omarchy-powerprofiles-set autodetect <profile>`. Mock profile clicks never
run that command.

## Security review checklist

- [ ] No network calls.
- [ ] No sudo, pkexec, polkit rule, or root helper.
- [ ] No sysfs writes or fan control.
- [ ] No SMART, no RAPL energy reads.
- [ ] Fixed profile allow-list; no arbitrary profile input.
- [ ] Helper and profile arguments use argv arrays, not shell strings.
- [ ] Sensor/profile labels are display-only and sanitized.
- [ ] Mock paths cannot escape `mock/`.
- [ ] No plugin-owned state files.
- [ ] Notifications off by default; normal urgency; discharge-only power notification.
- [ ] Preference-file side effect documented in README and maintainer notes.
- [ ] Built-in `omarchy.power` not disabled automatically.
- [ ] No permanent bar-layout edits from plugin runtime.

## Cleanup after development

The live test temporarily enables a symlinked plugin. Restore the user layout and remove the symlink:

```bash
omarchy plugin disable io.github.manish0467.thermal-power
rm ~/.config/omarchy/plugins/io.github.manish0467.thermal-power
```

Do **not** run `omarchy plugin remove` on the symlink. Restore `~/.config/omarchy/shell.json` from
the backup made before the test, then verify:

```bash
omarchy plugin list
test ! -e ~/.config/omarchy/plugins/io.github.manish0467.thermal-power
```

Never delete other plugins, checkouts, or state folders.

## Not run

- Hardware stress/load tests
- CPU burn-in or thermal soak tests
- Performance profile switching
- Fan control / PWM writes
- SMART reads
- Root or RAPL energy-counter access
- Network tests

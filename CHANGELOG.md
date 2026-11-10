# Changelog

## 0.1.0 — 2026-11-10

Initial release.

- Compact bar label for CPU temperature, battery watts/AC and an optional power-profile glyph.
- Detail panel with in-memory temperature history, per-core and other sensors, throttling evidence,
  frequency/governor/pstate, readable powercap limits, battery facts, fan RPM when exposed, and a
  fixed allow-list power-profile switcher.
- Explicit unavailable states for missing sensors, battery power, throttle counters, fan RPM and
  profile daemon.
- Optional, off-by-default sustained-temperature and sustained-discharge-power notifications with a
  15-minute cooldown.
- Read-only Python standard-library helper tested under Python 3.9 and 3.14.
- Development-only mock fixtures for normal, warm, hot, throttling, no-battery, no-sensors,
  missing profile daemon, AC charging and preview states.
- Documented Omarchy preference-file side effect for profile clicks and built-in `omarchy.power`
  overlap.

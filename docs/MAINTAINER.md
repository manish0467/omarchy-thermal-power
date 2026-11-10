# Maintainer notes

## Repository layout

```text
manifest.json          Omarchy plugin metadata and settings schema
BarWidget.qml          compact bar button and panel loader
Panel.qml              data owner, timers, UPower/PowerProfiles, profile switcher, UI
Model.js               pure formatting/state/history/notification logic
helper/thermal_power.py stdlib-only read-only sysfs collector
mock/<name>/scenario.json preview fixtures (never real sysfs)
tests/                 Node and Python tests, stress loop
docs/                  design, test plan and these notes
```

## Marketplace draft

- Category: **Hardware**
- Tags: **Bar**, **Power management**, **Quickshell**
- Do not submit without the owner's explicit approval.
- The plugin is a bar widget (`kinds: ["bar-widget"]`) and is placed in the right section by default.

### Marketplace checkbox 4 — files written

The submission must disclose this runtime side effect clearly:

> Clicking a power-profile button runs `omarchy-powerprofiles-set autodetect <profile>`. That Omarchy
> command writes Omarchy's per-power-source preference files
> `~/.local/state/omarchy/powerprofiles/ac` and
> `~/.local/state/omarchy/powerprofiles/battery`. The plugin does not create or directly edit these
> files and does not write them during polling. History and notification cooldowns are memory-only;
> there is no plugin state directory.

Installing/enabling/moving a widget changes `~/.config/omarchy/shell.json` through Omarchy's own
commands, not through plugin runtime code. Do not claim the plugin never changes the bar layout when
describing installation: it is Omarchy that edits the layout.

## Version compatibility

Tested against Omarchy `4.5.0-3`. The file `/usr/share/omarchy/version` may still say
`4.0.0.alpha`; trust `omarchy-version`. Mention this in release notes if the stale file confuses
testers.

## Development install and cleanup

1. Validate the real checkout first:

   ```bash
   cd ~/omarchy-thermal-power
   omarchy plugin validate .
   ```

2. Back up the live layout before temporarily enabling the widget:

   ```bash
   cp ~/.config/omarchy/shell.json /tmp/shell.json.before-thermal-power
   ```

3. Symlink the checkout into the plugin folder and enable it:

   ```bash
   ln -s ~/omarchy-thermal-power \
     ~/.config/omarchy/plugins/io.github.manish0467.thermal-power
   omarchy plugin enable io.github.manish0467.thermal-power
   ```

   The validator rejects a plugin root that is a symlink or contains symlinks, so validate before
   linking.

4. To remove a development symlink:

   ```bash
   omarchy plugin disable io.github.manish0467.thermal-power
   rm ~/.config/omarchy/plugins/io.github.manish0467.thermal-power
   ```

   Never run `omarchy plugin remove` on the symlink. Never delete other plugins, checkouts or state
   folders.

5. Restore the saved layout and verify the plugin is gone:

   ```bash
   cp /tmp/shell.json.before-thermal-power ~/.config/omarchy/shell.json
   omarchy plugin list
   test ! -e ~/.config/omarchy/plugins/io.github.manish0467.thermal-power
   ```

## Git workflow

- Work on a feature branch; base branch is `main`.
- Local commit identity must be:
  `Manish <252238345+manish0467@users.noreply.github.com>`
- Verify with `git log -1 --format='%an <%ae>'` before any push.
- Never push before explicit approval. Never force-push. Stop at the Git checkpoint and ask.
- Make a security self-review before committing; see `docs/TEST_PLAN.md`.

## Required checks before release

```bash
node tests/test_model.js
python3 -I tests/test_helper.py
python3 -I tests/stress_helper.py --runs 320
omarchy plugin validate .
qmllint BarWidget.qml Panel.qml
```

Also test under Python 3.9 if available. Re-run the stress loop under both interpreters after any
helper change. The loop is the permitted 300+ process-startup test; do not add hardware load or soak
tests.

Check that:

- mock fixtures do not read real sysfs;
- profile switching uses only `power-saver`/`balanced`/`performance` and the exact command
  `omarchy-powerprofiles-set autodetect <profile>`;
- no `sudo`, `pkexec`, polkit, network, SMART, fan control or RAPL energy read was introduced;
- README “What this plugin writes” and “What this plugin runs and reads” still match the code;
- the built-in `omarchy.power` is still present and the overlap instructions are correct;
- the README still says thresholds are starting points, not universal limits;
- the tested Omarchy version and stale `/usr/share/omarchy/version` note are current.

## Release cleanup

- Capture `preview.png` from a mock `preview` panel, not from real hardware.
- Remove `__pycache__` and any temporary screenshots from the repository.
- Ensure no symlink is inside the release tree.
- Restore the user's live layout and remove the development symlink.
- Do not create a tag, release, or marketplace submission without approval.

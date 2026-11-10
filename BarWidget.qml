import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Thin bar button. Panel.qml owns the helper process, UPower reads, history and
// the profile switcher; this file only forwards the open/close contract and
// paints the compact label.
BarWidget {
  id: root
  moduleName: "io.github.manish0467.thermal-power"

  readonly property var panel: panelLoader.item
  readonly property string overall: panel ? panel.overall : "unavailable"
  readonly property string barLabel: panel ? panel.barLabel : ""
  readonly property string tooltipText: panel ? panel.tooltipText : "Thermal & Power"
  readonly property color warmColor: Qt.rgba(0.88, 0.62, 0.14, 1)

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function open() { if (panel) panel.open() }
  function close() { if (panel) panel.close() }
  function togglePanel() { if (panel) panel.toggle() }
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }
  function refresh() { if (panel) panel.refresh() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.stateGlyph(root.overall)
    labelText: root.vertical ? "" : root.barLabel
    slotSize: Style.bar.iconSlot * (root.vertical ? 1 : Model.slotCountFor(root.barLabel, Style.bar.iconSlot))
    active: root.overall === "hot" || root.overall === "throttling"
    useActiveColor: true
    foreground: root.overall === "warm" ? root.warmColor : (root.bar ? root.bar.barForeground : Commons.Color.foreground)
    opacity: root.overall === "unavailable" ? 0.5 : 1.0
    tooltipText: root.tooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}

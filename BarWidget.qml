pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "ncc.yet-another-active-window"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Settings are clamped before they reach layout or effects.
  function clampInt(value, min, max, fallback) {
    var n = Math.round(Number(value))
    return isNaN(n) ? fallback : Math.max(min, Math.min(max, n))
  }

  readonly property var settingDefaults: ({
    iconSize: 18,
    iconSaturation: 100,
    maxWidth: 480,
    focusedTitleMaxWidth: 120,
    spacing: 4
  })

  readonly property int configuredIconSize: clampInt(setting("iconSize", root.settingDefaults.iconSize), 12, 24, root.settingDefaults.iconSize)
  readonly property int configuredSaturation: clampInt(setting("iconSaturation", root.settingDefaults.iconSaturation), 0, 200, root.settingDefaults.iconSaturation)
  readonly property int configuredMaxWidth: clampInt(setting("maxWidth", root.settingDefaults.maxWidth), 160, 1000, root.settingDefaults.maxWidth)
  readonly property int configuredTitleWidth: clampInt(setting("focusedTitleMaxWidth", root.settingDefaults.focusedTitleMaxWidth), 40, 400, root.settingDefaults.focusedTitleMaxWidth)
  readonly property int configuredSpacing: clampInt(setting("spacing", root.settingDefaults.spacing), 2, 8, root.settingDefaults.spacing)

  readonly property real saturationEffect: (configuredSaturation - 100) / 100

  readonly property int maxWidth: configuredMaxWidth
  readonly property int slotSize: configuredIconSize + 10
  readonly property int entrySpacing: configuredSpacing
  readonly property int maxTitleWidth: configuredTitleWidth
  readonly property int indicatorSlot: 32
  readonly property int verticalMaxEntries: 10

  readonly property int marqueeStartPause: 850   // ms at the start before scrolling
  readonly property int marqueeEndPause: 650     // ms at the end before reset
  readonly property int marqueeCyclePause: 6000  // ms idle between marquee cycles
  readonly property int marqueeSpeed: 40         // px per second

  readonly property int effectiveIconSize: root.vertical
    ? Math.max(12, Math.min(root.configuredIconSize, root.barSize - 16))
    : root.configuredIconSize

  readonly property var barScreen:
    root.QsWindow && root.QsWindow.window
      ? root.QsWindow.window.screen
      : null

  readonly property var hMonitor:
    barScreen ? Hyprland.monitorFor(barScreen) : Hyprland.focusedMonitor

  readonly property var activeWorkspace:
    hMonitor ? hMonitor.activeWorkspace : null

  readonly property var windows: {
    var result = []
    if (!hMonitor || !activeWorkspace || activeWorkspace.id <= 0) return result

    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      if (!t || !t.monitor || !t.workspace) continue
      if (t.monitor.id !== hMonitor.id) continue
      if (t.workspace.id !== activeWorkspace.id) continue
      result.push(t)
    }
    return result
  }

  property var windowOrder: []

  Component.onCompleted: root.syncWindowOrder()

  function syncWindowOrder() {
    var live = Hyprland.toplevels.values || []
    var order = root.windowOrder
    var next = []
    for (var i = 0; i < order.length; i++) {
      if (live.indexOf(order[i]) !== -1) next.push(order[i])
    }
    for (var j = 0; j < windows.length; j++) {
      if (next.indexOf(windows[j]) === -1) next.push(windows[j])
    }
    var same = next.length === order.length
    for (var k = 0; k < next.length && same; k++) {
      if (next[k] !== order[k]) same = false
    }
    if (!same) root.windowOrder = next
  }

  onWindowsChanged: root.syncWindowOrder()

  // Toplevel object identity stays stable for the window lifetime.
  function moveWindowRelative(source, target, after) {
    if (!source || !target || source === target) return
    var next = root.windowOrder.slice()
    var sourceIndex = next.indexOf(source)
    if (sourceIndex === -1) return
    next.splice(sourceIndex, 1)
    var targetIndex = next.indexOf(target)
    if (targetIndex === -1) return
    next.splice(targetIndex + (after ? 1 : 0), 0, source)

    var changed = next.length !== root.windowOrder.length
    for (var i = 0; i < next.length && !changed; i++)
      if (next[i] !== root.windowOrder[i]) changed = true
    if (changed) root.windowOrder = next
  }

  function reorderVisibleWindow(source, point) {
    var repeater = root.vertical ? verticalEntries : horizontalEntries
    var axis = root.vertical ? point.y : point.x
    var last = null

    for (var i = 0; i < repeater.count; i++) {
      var item = repeater.itemAt(i)
      if (!item || !item.win || item.win === source) continue
      var center = item.mapToItem(root, item.width / 2, item.height / 2)
      var itemAxis = root.vertical ? center.y : center.x
      if (axis < itemAxis) {
        root.moveWindowRelative(source, item.win, false)
        return
      }
      last = item.win
    }
    if (last) root.moveWindowRelative(source, last, true)
  }

  readonly property var visibleWindows: {
    var candidates = []
    for (var i = 0; i < root.windowOrder.length; i++) {
      if (windows.indexOf(root.windowOrder[i]) !== -1) candidates.push(root.windowOrder[i])
    }
    var count = Math.min(root.layout.visibleCount, candidates.length)
    var out = candidates.slice(0, count)
    var focused = Hyprland.activeToplevel
    // Keep an overflowed focused window in the final visible slot.
    if (focused !== null && count > 0 && out.indexOf(focused) === -1 && candidates.indexOf(focused) !== -1) {
      out[count - 1] = focused
    }
    return out
  }

  readonly property var layout: computeLayout(windows.length)

  function computeLayout(count) {
    if (root.vertical) {
      var vVisible = Math.min(count, root.verticalMaxEntries)
      return { visibleCount: vVisible, hidden: count - vVisible, titleWidth: 0 }
    }
    if (count === 0) return { visibleCount: 0, hidden: 0, titleWidth: 0 }

    var visible = count
    while (true) {
      var hidden = count - visible
      var slots = visible + (hidden > 0 ? 1 : 0)
      var fixed = visible * root.slotSize
        + (hidden > 0 ? root.indicatorSlot : 0)
        + Math.max(0, slots - 1) * root.entrySpacing
      var titleBudget = root.maxWidth - fixed
      if (titleBudget >= 0)
        return { visibleCount: visible, hidden: hidden, titleWidth: Math.min(titleBudget, root.maxTitleWidth) }
      if (visible === 1) return { visibleCount: 1, hidden: count - 1, titleWidth: 0 }
      visible--
    }
  }

  function glyphFor(toplevel) {
    var cls = toplevel && toplevel.lastIpcObject ? String(toplevel.lastIpcObject.class || "") : ""
    return cls.length > 0 ? cls.charAt(0).toUpperCase() : "\u25A1"
  }

  readonly property bool debugIcons: false

  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null

  function normalizeCandidate(value) {
    var v = String(value === undefined || value === null ? "" : value).trim()
    if (v.slice(-8) === ".desktop") v = v.slice(0, -8)
    return v
  }

  function candidatesFor(toplevel) {
    var meta = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : {}
    var appId = toplevel && toplevel.wayland ? root.normalizeCandidate(toplevel.wayland.appId) : ""
    var cls = root.normalizeCandidate(meta["class"])
    var initial = root.normalizeCandidate(meta.initialClass)

    var names = []
    var push = function(v) {
      if (v.length > 0 && names.indexOf(v) === -1) names.push(v)
    }
    push(cls)
    push(initial)
    push(appId)
    return { names: names, key: [appId, cls, initial].join("|") }
  }

  function fallbackIconNames(toplevel, identityNames) {
    var out = []
    var push = function(value) {
      var name = root.normalizeCandidate(value)
      if (name.length > 0 && out.indexOf(name) === -1) out.push(name)
    }

    for (var i = 0; i < identityNames.length; i++) push(identityNames[i])

    var segments = root.candidateSegments(identityNames)
    for (var j = 0; j < segments.length; j++) push(segments[j])

    var meta = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : {}
    push(meta.initialTitle)
    return out
  }

  property var iconCache: ({})

  function entryById(candidate) {
    if (!candidate || candidate.length === 0) return null
    var e = DesktopEntries.byId(candidate)
    if (e && !e.noDisplay) return e
    return null
  }

  function entryIdEquals(entryId, candidate) {
    var id = String(entryId || "").trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    return id.toLowerCase() === String(candidate).toLowerCase() && id.length > 0
  }

  function execBasename(entry) {
    var cmd = entry && entry.command && entry.command.length > 0 ? String(entry.command[0]) : ""
    var slash = cmd.lastIndexOf("/")
    return slash >= 0 ? cmd.slice(slash + 1) : cmd
  }

  function uniqueEntryByIcon(matches) {
    if (matches.length === 0) return null
    var icon = String(matches[0].icon || "")
    for (var i = 1; i < matches.length; i++) {
      if (String(matches[i].icon || "") !== icon) return null
    }
    return matches[0]
  }

  function resolveEntry(names, onPass) {
    var hit = function(entry, pass) {
      if (onPass) onPass(pass)
      return entry
    }
    var values = DesktopEntries.applications.values || []

    for (var i = 0; i < names.length; i++) {
      var exact = root.entryById(names[i])
      if (exact) return hit(exact, "exact-id")
    }

    for (var j = 0; j < values.length; j++) {
      var cand = values[j]
      if (cand.noDisplay) continue
      var sc = String(cand.startupClass || "").toLowerCase()
      if (sc.length === 0) continue
      for (var k = 0; k < names.length; k++) {
        if (sc === names[k].toLowerCase()) return hit(cand, "startup-class")
      }
    }

    for (var m = 0; m < names.length; m++) {
      var lower = names[m].toLowerCase()
      for (var n = 0; n < values.length; n++) {
        var byLower = values[n]
        if (!byLower.noDisplay && root.entryIdEquals(byLower.id, lower)) return hit(byLower, "id-ci")
      }
    }

    for (var p = 0; p < names.length; p++) {
      try {
        var guess = DesktopEntries.heuristicLookup(names[p])
        if (guess && !guess.noDisplay) return hit(guess, "heuristic")
      } catch (err) { /* native lookup unavailable */ }
    }

    for (var q = 0; q < names.length; q++) {
      var want = names[q].toLowerCase()
      var matches = []
      for (var r = 0; r < values.length; r++) {
        var entry = values[r]
        if (entry.noDisplay) continue
        var nameHit = String(entry.name || "").toLowerCase() === want
        var execHit = root.execBasename(entry).toLowerCase() === want
        if (nameHit || execHit) {
          if (!matches.some(function(prev) { return prev.id === entry.id })) matches.push(entry)
        }
      }
      var unified = root.uniqueEntryByIcon(matches)
      if (unified) return hit(unified, "name-exec")
    }

    var webApp = root.webAppEntryFor(names)
    if (webApp) return hit(webApp, "webapp")

    return null
  }

  readonly property string webAppStopWords:
    "|www|com|net|org|gov|edu|int|io|co|dev|app|web|mail|html|htm|default|profile|index|login|auth|mobile|new|home|main|site|"

  function isWebAppStopWord(word) {
    return String(word).length < 3 || root.webAppStopWords.indexOf("|" + word + "|") !== -1
  }

  function urlHostsIn(text) {
    var out = []
    var re = /[a-z][a-z0-9+.-]*:\/\/[a-z0-9._-]+/gi
    var m
    while ((m = re.exec(String(text || ""))) !== null) {
      var host = m[0].slice(m[0].indexOf("://") + 3).toLowerCase()
      if (host.length >= 5 && host.indexOf(".") > 0 && out.indexOf(host) === -1) out.push(host)
    }
    return out
  }

  function candidateSegments(candidates) {
    var segs = []
    for (var i = 0; i < candidates.length; i++) {
      var tokens = String(candidates[i]).toLowerCase().split(/[-_\s]+/)
      for (var j = 0; j < tokens.length; j++) {
        if (tokens[j].indexOf(".") === -1) continue
        var parts = tokens[j].split(".")
        for (var k = 0; k < parts.length - 1; k++) {
          var p = parts[k]
          if (!root.isWebAppStopWord(p) && segs.indexOf(p) === -1) segs.push(p)
        }
      }
    }
    return segs
  }

  function entryCommandWords(entry) {
    var base = root.execBasename(entry).toLowerCase().replace(/\.[a-z]+$/, "")
    var words = []
    var parts = base.split(/[-_.\s]+/)
    for (var i = 0; i < parts.length; i++) {
      if (!root.isWebAppStopWord(parts[i]) && words.indexOf(parts[i]) === -1) words.push(parts[i])
    }
    return words
  }

  function webAppEntryFor(names) {
    var values = DesktopEntries.applications.values || []
    var segments = root.candidateSegments(names)
    var matches = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (e.noDisplay) continue
      var matched = false
      var hosts = root.urlHostsIn(e.execString)
      for (var h = 0; h < hosts.length && !matched; h++) {
        for (var c = 0; c < names.length; c++) {
          if (names[c].toLowerCase().indexOf(hosts[h]) !== -1) { matched = true; break }
        }
      }
      if (!matched && segments.length > 0) {
        var words = root.entryCommandWords(e)
        for (var w = 0; w < words.length && !matched; w++) {
          if (segments.indexOf(words[w]) !== -1) matched = true
        }
      }
      if (matched && !matches.some(function(prev) { return prev.id === e.id })) matches.push(e)
    }
    return root.uniqueEntryByIcon(matches)
  }

  property int appListRevision: 0

  // The plugin API exposes appsChanged, not AppLibrary's internal icon index.
  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.appListRevision++ }
  }

  function iconFor(toplevel) {
    var identity = root.candidatesFor(toplevel)
    if (identity.names.length === 0) return ""

    var cached = root.iconCache[identity.key]
    // Desktop-entry matches are stable; generic fallbacks are provisional.
    if (cached !== undefined && cached.url !== "" && !cached.provisional) return cached.url

    var entryCount = (DesktopEntries.applications.values || []).length
    var lib = root.appLibrary
    var rev = entryCount + "/" + root.appListRevision + "/" + (lib ? 1 : 0)

    if (cached !== undefined && cached.rev === rev) return cached.url
    if (entryCount === 0) return ""

    var url = ""
    var entry = null
    var reason = ""
    try {
      entry = root.resolveEntry(identity.names, function(passed) { reason = passed })
      if (!entry) {
        var iconNames = root.fallbackIconNames(toplevel, identity.names)
        for (var i = 0; i < iconNames.length; i++) {
          var candidate = iconNames[i]
          if (candidate.length === 0) continue
          var iconUrl = String(Quickshell.iconPath(candidate, true))
          if (iconUrl.length > 0) {
            entry = { icon: candidate, name: "", id: "generic:" + candidate }
            reason = "generic-identity"
            url = iconUrl
            break
          }
        }
        if (!entry) {
          entry = { icon: "application-x-executable", name: "", id: "generic:application-x-executable" }
          reason = "generic-fallback"
          url = String(Quickshell.iconPath("application-x-executable", true))
        }
      }
    } catch (err) {
      if (root.debugIcons) console.warn("[ncc.window-icons] resolve error:", err)
    }
    if (entry && url.length === 0) {
      var lib = root.appLibrary
      if (lib && typeof lib.iconSource === "function") {
        url = String(lib.iconSource(entry.icon))
      } else {
        url = String(Quickshell.iconPath(entry.icon, true))
      }
    }

    root.iconCache[identity.key] = {
      url: url,
      entryId: entry ? String(entry.id) : "",
      appName: entry ? String(entry.name || "") : "",
      names: identity.names,
      provisional: reason === "generic-identity" || reason === "generic-fallback",
      rev: rev
    }
    if (root.debugIcons) {
      console.warn("[ncc.window-icons] appId=" + identity.key.split("|")[0]
        + " class=" + identity.names.join("/")
        + " matchedDesktopId=" + (entry ? String(entry.id) : "<none>")
        + " matchReason=" + (reason || "unresolved")
        + " icon=" + (entry ? String(entry.icon) : "<none>")
        + " source=" + url)
    }
    return url
  }

  function formatTitle(toplevel) {
    if (!toplevel) return ""
    var raw = String(toplevel.title || "").replace(/\s+/g, " ").trim()
    var identity = root.candidatesFor(toplevel)
    var cached = root.iconCache[identity.key]
    var app = cached && cached.appName ? String(cached.appName).trim() : ""

    if (app.length === 0) return raw
    if (raw.length === 0) return app

    var rl = raw.toLowerCase()
    var al = app.toLowerCase()
    if (rl.indexOf(al) !== -1) return raw
    return raw + " \u2013 " + app
  }

  property bool settingsOpen: false
  readonly property bool opened: settingsOpen

  function open() {
    overflowOpen = false
    syncDraftSettings()
    settingsOpen = true
  }

  function close() { settingsOpen = false }

  function togglePanel() {
    if (settingsOpen) close()
    else open()
  }

  property int draftIconSize: configuredIconSize
  property int draftSaturation: configuredSaturation
  property int draftMaxWidth: configuredMaxWidth
  property int draftTitleWidth: configuredTitleWidth
  property int draftSpacing: configuredSpacing

  function syncDraftSettings() {
    draftIconSize = configuredIconSize
    draftSaturation = configuredSaturation
    draftMaxWidth = configuredMaxWidth
    draftTitleWidth = configuredTitleWidth
    draftSpacing = configuredSpacing
  }

  function previewSetting(key, value) {
    var next = Object.assign({}, settings || {})
    next[key] = Math.round(value)
    settings = next
  }

  function saveSetting(key, value) {
    previewSetting(key, value)
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  function resetSettings() {
    var next = Object.assign({}, settings || {})
    for (var key in root.settingDefaults)
      next[key] = root.settingDefaults[key]
    settings = next
    syncDraftSettings()
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  property bool overflowOpen: false

  readonly property var hiddenWindows: {
    var out = []
    for (var i = 0; i < windowOrder.length; i++) {
      var t = windowOrder[i]
      if (windows.indexOf(t) !== -1 && visibleWindows.indexOf(t) === -1)
        out.push(t)
    }
    return out
  }

  onHiddenWindowsChanged: {
    if (overflowOpen && hiddenWindows.length === 0)
      overflowOpen = false
  }

  function toggleOverflow() {
    if (overflowOpen) {
      overflowOpen = false
      return
    }
    if (settingsOpen) close()
    overflowOpen = true
  }

  QtObject {
    id: overflowOwner

    function close() { root.overflowOpen = false }
  }

  implicitWidth: vertical ? Style.bar.sizeVertical : row.implicitWidth
  implicitHeight: vertical ? column.implicitHeight : barSize

  Item {
    anchors.fill: parent
    clip: true

    Row {
      id: row
      visible: !root.vertical
      spacing: root.entrySpacing

      Repeater {
        id: horizontalEntries
        model: root.layout.visibleCount
        delegate: Entry {}
      }

      Repeater {
        model: root.layout.hidden > 0 ? 1 : 0
        delegate: Overflow {}
      }
    }

    Column {
      id: column
      visible: root.vertical
      spacing: root.vertical ? root.configuredSpacing : 2

      Repeater {
        id: verticalEntries
        model: root.vertical ? root.layout.visibleCount : 0
        delegate: Entry {}
      }

      Repeater {
        model: root.vertical && root.layout.hidden > 0 ? 1 : 0
        delegate: Overflow {}
      }
    }
  }

  component Entry: Item {
    id: entry
    required property int index

    readonly property var win: index < root.visibleWindows.length ? root.visibleWindows[index] : null
    readonly property bool focused: win !== null && win === Hyprland.activeToplevel
    readonly property bool hovered: area.containsMouse
    readonly property bool showTitle: focused && (root.vertical || root.layout.titleWidth > 0)
    readonly property real glyphSlot: root.vertical ? width : root.slotSize

    readonly property bool interactive: win !== null
    readonly property bool tooltipHovered: entry.interactive && !root.settingsOpen && area.containsMouse

    readonly property string displayTitle: {
      if (!win) return ""
      root.iconFor(win)
      return root.formatTitle(win)
    }

    function triggerPress(button) {
      if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(entry)
      if (!entry.win || !entry.win.wayland) return
      if (button === Qt.MiddleButton) {
        entry.win.wayland.close()
      } else if (button === Qt.RightButton) {
        root.togglePanel()
      } else {
        if (root.settingsOpen) root.close()
        entry.win.wayland.activate()
      }
    }

    property var registeredBar: null

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget)
        registeredBar.unregisterClickTarget(entry)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget)
        registeredBar.registerClickTarget(entry)
    }

    readonly property var watchedBar: root.bar
    onWatchedBarChanged: syncClickRegistration()
    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: {
      if (registeredBar && registeredBar.unregisterClickTarget)
        registeredBar.unregisterClickTarget(entry)
    }

    width: root.vertical ? root.barSize : root.slotSize + (showTitle ? root.layout.titleWidth : 0)
    height: root.vertical ? root.barSize : root.barSize

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: Util.alpha(Color.foreground, entry.hovered ? 0.16 : (entry.focused ? 0.08 : 0))
    }

    Item {
      width: root.vertical ? parent.width : entry.glyphSlot
      height: root.vertical ? root.effectiveIconSize + 4 : parent.height
      x: root.vertical ? 0 : 0
      y: root.vertical ? 0 : 0
      opacity: entry.focused ? 1.0 : 0.55

      readonly property string iconUrl: entry.win ? root.iconFor(entry.win) : ""

      Image {
        anchors.centerIn: parent
        visible: parent.iconUrl.length > 0
        width: root.vertical ? root.effectiveIconSize : root.configuredIconSize
        height: root.vertical ? root.effectiveIconSize : root.configuredIconSize
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        // Avoid upscaling a logical-pixel decode on HiDPI screens.
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: parent.iconUrl.length > 0 ? parent.iconUrl : ""
        layer.enabled: root.saturationEffect !== 0
        layer.smooth: true
        layer.effect: MultiEffect {
          saturation: root.saturationEffect
        }
      }

      Text {
        anchors.fill: parent
        visible: parent.iconUrl.length === 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: root.glyphFor(entry.win)
        color: Color.foreground
        font.pixelSize: Style.font.body
      }
    }

    Item {
      id: titleClip
      x: root.vertical ? 0 : entry.glyphSlot
      y: root.vertical ? (root.effectiveIconSize + root.configuredSpacing) : 0
      width: root.vertical ? parent.width : parent.width - entry.glyphSlot
      height: root.vertical ? (parent.height - root.effectiveIconSize - root.configuredSpacing) : parent.height
      clip: true
      visible: entry.showTitle

      readonly property bool overflowing: titleText.contentWidth > width + 1

      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        x: 0
        y: 0
        textFormat: Text.PlainText
        text: entry.displayTitle
        color: Color.foreground
        font.pixelSize: Style.font.body
      }

      SequentialAnimation {
        id: marquee

        running: entry.showTitle && titleClip.overflowing && !entry.hovered && !Style.reduceMotion
        loops: Animation.Infinite

        PropertyAction { target: titleText; property: "x"; value: 0 }
        PauseAnimation { duration: Style.duration(root.marqueeStartPause) }
        NumberAnimation {
          target: titleText
          property: "x"
          to: -(titleText.contentWidth - titleClip.width)
          duration: Style.duration(Math.max(300, Math.round((titleText.contentWidth - titleClip.width) * 1000 / root.marqueeSpeed)))
        }
        PauseAnimation { duration: Style.duration(root.marqueeEndPause) }
        PropertyAction { target: titleText; property: "x"; value: 0 }
        PauseAnimation { duration: Style.duration(root.marqueeCyclePause) }

        onRunningChanged: if (!running) titleText.x = 0
      }
    }

    MouseArea {
      id: area
      // Omarchy reserves left-drag for moving the whole widget.
      property real reorderPressX: 0
      property real reorderPressY: 0
      property var reorderWindow: null
      property bool reordering: false
      property bool suppressMiddleClick: false

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      enabled: entry.interactive
      hoverEnabled: true
      cursorShape: reordering ? Qt.ClosedHandCursor : Qt.PointingHandCursor

      onPressed: function(mouse) {
        if (mouse.button !== Qt.MiddleButton) return
        reorderPressX = mouse.x
        reorderPressY = mouse.y
        reorderWindow = entry.win
        reordering = false
        suppressMiddleClick = false
      }

      onPositionChanged: function(mouse) {
        if (!(mouse.buttons & Qt.MiddleButton) || !reorderWindow) return
        var distance = Math.abs(mouse.x - reorderPressX) + Math.abs(mouse.y - reorderPressY)
        if (!reordering && distance >= Style.space(4)) {
          reordering = true
          suppressMiddleClick = true
          if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(entry)
        }
        if (reordering)
          root.reorderVisibleWindow(reorderWindow, mapToItem(root, mouse.x, mouse.y))
      }

      onReleased: function(mouse) {
        if (mouse.button !== Qt.MiddleButton) return
        reordering = false
        reorderWindow = null
      }

      onCanceled: {
        reordering = false
        reorderWindow = null
        suppressMiddleClick = false
      }

      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton && suppressMiddleClick) {
          suppressMiddleClick = false
          return
        }
        entry.triggerPress(mouse.button)
      }

      onEntered: {
        if (!entry.win || !root.bar || !root.bar.showTooltip) return
        if (root.settingsOpen) return
        if (!entry.focused)
          root.bar.showTooltip(entry, entry.displayTitle)
      }
      onExited: {
        if (root.bar && root.bar.hideTooltip)
          root.bar.hideTooltip(entry)
      }
    }
  }

  component Overflow: Item {
    id: overflow

    width: root.vertical ? root.barSize : root.indicatorSlot
    height: root.vertical ? root.barSize : root.barSize

    function triggerPress(button) {
      if (button === Qt.RightButton) root.togglePanel()
      else if (button === Qt.LeftButton) root.toggleOverflow()
    }

    property var registeredBar: null
    readonly property var watchedBar: root.bar

    function syncClickRegistration() {
      if (overflow.registeredBar && overflow.registeredBar.unregisterClickTarget)
        overflow.registeredBar.unregisterClickTarget(overflow)
      overflow.registeredBar = overflow.watchedBar
      if (overflow.registeredBar && overflow.registeredBar.registerClickTarget)
        overflow.registeredBar.registerClickTarget(overflow)
    }

    onWatchedBarChanged: overflow.syncClickRegistration()
    Component.onCompleted: overflow.syncClickRegistration()
    Component.onDestruction: {
      if (overflow.registeredBar && overflow.registeredBar.unregisterClickTarget)
        overflow.registeredBar.unregisterClickTarget(overflow)
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "+" + root.layout.hidden
      color: Color.foreground
      opacity: 0.55
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { overflow.triggerPress(mouse.button) }
    }
  }

  PopupCard {
    id: settingsPopup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.settingsOpen
    contentWidth: fittedContentWidth(Style.space(330))
    contentHeight: fittedContentHeight(settingsColumn.implicitHeight)

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        text: strings.t("settings.title")
        textFormat: Text.PlainText
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      SettingSlider {
        label: strings.t("settings.iconSize")
        suffix: "px"
        minimum: 12
        maximum: 24
        step: 1
        currentValue: root.draftIconSize
        onCommitted: function(value) {
          root.draftIconSize = value
          root.saveSetting("iconSize", value)
        }
      }

      SettingSlider {
        label: strings.t("settings.iconSaturation")
        suffix: "%"
        minimum: 0
        maximum: 200
        step: 5
        currentValue: root.draftSaturation
        onCommitted: function(value) {
          root.draftSaturation = value
          root.saveSetting("iconSaturation", value)
        }
      }

      SettingSlider {
        label: strings.t("settings.maximumWidth")
        suffix: "px"
        minimum: 160
        maximum: 1000
        step: 10
        currentValue: root.draftMaxWidth
        onCommitted: function(value) {
          root.draftMaxWidth = value
          root.saveSetting("maxWidth", value)
        }
        visible: !root.vertical
      }

      SettingSlider {
        label: strings.t("settings.focusedTitleWidth")
        suffix: "px"
        minimum: 40
        maximum: 400
        step: 10
        currentValue: root.draftTitleWidth
        onCommitted: function(value) {
          root.draftTitleWidth = value
          root.saveSetting("focusedTitleMaxWidth", value)
        }
        visible: !root.vertical
      }

      SettingSlider {
        label: strings.t("settings.spacing")
        suffix: "px"
        minimum: 2
        maximum: 8
        step: 1
        currentValue: root.draftSpacing
        onCommitted: function(value) {
          root.draftSpacing = value
          root.saveSetting("spacing", value)
        }
      }

      Button {
        width: settingsColumn.width
        text: strings.t("settings.reset")
        onClicked: root.resetSettings()
      }
    }
  }

  PopupCard {
    id: overflowPopup
    anchorItem: root
    bar: root.bar
    owner: overflowOwner
    open: root.overflowOpen
    contentWidth: fittedContentWidth(Style.space(260))
    contentHeight: fittedContentHeight(overflowColumn.implicitHeight)

    Flickable {
      id: overflowFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: overflowColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      clip: true

      Column {
        id: overflowColumn
        width: overflowFlick.width
        spacing: Style.space(4)

        Repeater {
          model: root.hiddenWindows
          delegate: OverflowRow {}
        }
      }
    }
  }

  component OverflowRow: Rectangle {
    id: overflowRow

    required property var modelData
    readonly property var win: modelData
    readonly property bool hovered: rowArea.containsMouse
    readonly property string iconUrl: win ? root.iconFor(win) : ""
    readonly property string rowTitle: win ? root.formatTitle(win) : ""

    width: parent ? parent.width : 0
    height: Style.space(26)
    radius: 4
    color: Util.alpha(Color.foreground, hovered ? 0.14 : 0)

    Item {
      id: rowIconSlot
      width: Style.space(24)
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Image {
        anchors.centerIn: parent
        visible: overflowRow.iconUrl.length > 0
        width: Style.space(16)
        height: Style.space(16)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: overflowRow.iconUrl.length > 0 ? overflowRow.iconUrl : ""
      }

      Text {
        anchors.fill: parent
        visible: overflowRow.iconUrl.length === 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: root.glyphFor(overflowRow.win)
        color: Color.foreground
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      anchors.left: rowIconSlot.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: overflowRow.rowTitle
      color: Color.foreground
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onClicked: function(mouse) {
        if (!overflowRow.win || !overflowRow.win.wayland) return
        if (mouse.button === Qt.MiddleButton) {
          overflowRow.win.wayland.close()
          return
        }
        overflowRow.win.wayland.activate()
        root.overflowOpen = false
      }
    }
  }

  component SettingSlider: Column {
    id: sliderSetting

    required property string label
    property string suffix: ""
    required property int minimum
    required property int maximum
    required property int step
    required property int currentValue

    signal committed(int value)

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(5)

    Item {
      width: parent.width
      implicitHeight: Math.max(settingLabel.implicitHeight, settingValue.implicitHeight)

      Text {
        id: settingLabel
        anchors.left: parent.left
        textFormat: Text.PlainText
        text: sliderSetting.label
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        id: settingValue
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: Math.round(slider.dragging ? slider.liveValue : sliderSetting.currentValue) + sliderSetting.suffix
        color: root.bar ? Qt.darker(root.bar.foreground, 1.35) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    PanelSlider {
      id: slider
      width: sliderSetting.width
      bar: root.bar
      minimum: sliderSetting.minimum
      maximum: sliderSetting.maximum
      step: sliderSetting.step
      integer: true
      value: sliderSetting.currentValue
      onReleased: function(value) { sliderSetting.committed(Math.round(value)) }
    }
  }
}

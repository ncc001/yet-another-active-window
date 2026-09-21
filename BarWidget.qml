pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Window list for the monitor + active workspace this bar instance lives on.
//
// Reactive Hyprland toplevel model with desktop-entry icons resolved through
// Quickshell's native icon lookup, activate on left click, close on middle
// click. Everything reacts through bindings — no polling, no dispatch.
BarWidget {
  id: root
  moduleName: "ncc.yet-another-active-window"

  // ---- Width contract --------------------------------------------------
  // root.implicitWidth is what the ModuleSlot consumes; it is derived from
  // computeLayout() and can never exceed maxWidth. Delegates read fixed slot
  // sizes; only the focused entry takes leftover budget, so there is no
  // width <-> implicitWidth feedback loop and no Layout.* attached props.
  //
  // ---- Visual settings -------------------------------------------------
  // Native inline shell.json settings (setting() from the BarWidget base,
  // persisted via bar.shell.updateEntryInline), clamped on read so malformed
  // values can never break the widget. One normalized source of truth per
  // setting; delegates read the configured* properties, never raw setting().
  function clampInt(value, min, max, fallback) {
    var n = Math.round(Number(value))
    return isNaN(n) ? fallback : Math.max(min, Math.min(max, n))
  }

  // Canonical visual defaults — single source used both by the configured*
  // readers below and by the "Reset to defaults" action.
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
  readonly property int configuredSpacing: clampInt(setting("spacing", root.settingDefaults.spacing), 2, 12, root.settingDefaults.spacing)

  // MultiEffect saturation mapping: 0% -> -1 grayscale, 100% -> 0 original,
  // 200% -> +1 strongly oversaturated.
  readonly property real saturationEffect: (configuredSaturation - 100) / 100

  // Derived geometry: the icon slot wraps the icon with fixed horizontal
  // padding, so changing icon size feeds deterministically into the layout
  // budget and overflow math below.
  readonly property int maxWidth: configuredMaxWidth
  readonly property int slotSize: configuredIconSize + 10
  readonly property int entrySpacing: configuredSpacing
  readonly property int maxTitleWidth: configuredTitleWidth
  readonly property int indicatorSlot: 32
  readonly property int verticalMaxEntries: 10

  // Marquee internals (no settings UI yet). Duration is derived from the
  // overflow distance: duration = distance / marqueeSpeed, so long titles
  // scroll proportionally longer.
  readonly property int marqueeStartPause: 850   // ms at the start before scrolling
  readonly property int marqueeEndPause: 650     // ms at the end before reset
  readonly property int marqueeCyclePause: 6000  // ms idle between marquee cycles
  readonly property int marqueeSpeed: 40         // px per second

  // ---- Monitor / workspace resolution -----------------------------------
  readonly property var barScreen:
    root.QsWindow && root.QsWindow.window
      ? root.QsWindow.window.screen
      : null

  readonly property var hMonitor:
    barScreen ? Hyprland.monitorFor(barScreen) : Hyprland.focusedMonitor

  readonly property var activeWorkspace:
    hMonitor ? hMonitor.activeWorkspace : null

  // ---- Reactive window model ---------------------------------------------
  // Reading toplevels.values plus each toplevel's monitor/workspace inside
  // this binding tracks opens, closes, workspace moves and monitor moves.
  // Focus and title changes flow through Hyprland.activeToplevel reads in
  // delegates and toplevel.title reads below.
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

  // ---- Stable display order -------------------------------------------------
  // Browser-tab-like ordering: windows appear where they first appeared and
  // stay there. windowOrder stores toplevel object references (stable for
  // the lifetime of each window); membership comes reactively from the
  // filtered `windows` list, never from focus or titles.
  property var windowOrder: []

  Component.onCompleted: root.syncWindowOrder()

  // Sync stored order with current reality: drop dead windows, append
  // unseen ones. Runs only when the filtered membership changes — focus
  // and title churn never reach this path.
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

  // Rendered entries: the first visibleCount windows in stable order. If
  // the focused window would fall outside them, it replaces ONLY the last
  // visible slot — it never jumps to the front. Hidden count (+N) is
  // unaffected by the swap. Recomputing this on focus changes touches no
  // stored ordering state.
  readonly property var visibleWindows: {
    var candidates = []
    for (var i = 0; i < root.windowOrder.length; i++) {
      if (windows.indexOf(root.windowOrder[i]) !== -1) candidates.push(root.windowOrder[i])
    }
    var count = Math.min(root.layout.visibleCount, candidates.length)
    var out = candidates.slice(0, count)
    var focused = Hyprland.activeToplevel
    if (focused !== null && count > 0 && out.indexOf(focused) === -1 && candidates.indexOf(focused) !== -1) {
      out[count - 1] = focused
    }
    return out
  }

  // Deterministic width budget: fixed slots first, focused title gets what
  // is left (shrinks first as content approaches maxWidth), then trailing
  // entries drop into "+N". Always terminates at one visible entry.
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
      var fixed = slots * root.slotSize + Math.max(0, slots - 1) * root.entrySpacing
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

  // ---- Icon resolution ---------------------------------------------------
  // Window identity (wayland appId + Hyprland class/initialClass) ->
  // desktop entry -> icon URL, with Quickshell's native icon lookup as the
  // final path resolver. No subprocesses: matching runs over Quickshell's
  // in-memory DesktopEntries.
  readonly property bool debugIcons: false

  // Bar plugins do not receive the shell's menu-only AppLibrary service.
  function iconSource(icon) {
    var value = String(icon || "")
    if (!value) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  property int desktopEntriesRevision: 0
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.desktopEntriesRevision++ }
  }

  function normalizeCandidate(value) {
    var v = String(value === undefined || value === null ? "" : value).trim()
    if (v.slice(-8) === ".desktop") v = v.slice(0, -8)
    return v
  }

  // Ordered unique identity candidates for one window: appId, class,
  // initialClass. Originals are kept in the cache entry for debugging and
  // for the future PWA slice; matching itself is case-insensitive.
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

  // Cache keyed by the full identity tuple "appId|class|initialClass", not
  // by class alone: windows can share a class while differing in appId
  // (Chromium/PWA). Values carry the desktop-entry id, both match keys, the
  // resolved URL and the revision it was resolved at. Mutated in place from
  // bindings — never reassigned — so hits cost one property read and
  // focus/title churn never rescans. Unresolved entries retry whenever the
  // desktop-entry model or PID lookup results change (see iconFor).
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

  // Several desktop entries may describe the SAME application (client /
  // server / daemon launcher variants share Exec and Icon, e.g. foot and
  // foot-server). For icon purposes a set of matches is unambiguous when
  // every member resolves to the same icon name; otherwise stay unresolved
  // — placeholder beats wrong icon.
  function uniqueEntryByIcon(matches) {
    if (matches.length === 0) return null
    var icon = String(matches[0].icon || "")
    for (var i = 1; i < matches.length; i++) {
      if (String(matches[i].icon || "") !== icon) return null
    }
    return matches[0]
  }

  // Generic matcher over the normalized candidate set:
  //   A. exact DesktopEntry id
  //   B. exact StartupWMClass (case-insensitive)
  //   C. case-insensitive DesktopEntry id
  //   D. Quickshell heuristicLookup
  //   E. conservative unique Name / executable-basename match
  //   F. web-app / command-line match (URL hosts + handler-name words)
  // NoDisplay entries never win a match; ambiguity loses on purpose.
  // `onPass` (optional) receives the winning pass name for diagnostics.
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

  // ---- Web-app / command-line matching (pass F) ---------------------------
  // Omarchy web apps launch `chromium --app=<url>` from a desktop entry
  // whose Exec carries the same URL, and Chromium embeds that URL's host
  // verbatim in the window class ("chrome-web.whatsapp.com__-Default").
  // Matching is therefore generic: URL hosts found in an entry's command
  // line matched by substring into the window identity, plus distinctive
  // words of the command basename (handler scripts such as
  // "...-handler-hey" carry no URL) matched against embedded host segments.
  // Ambiguity loses on purpose: placeholder beats wrong icon.
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

  // Dot-separated segments of dotted tokens embedded in the candidates,
  // TLD excluded. "chrome-app.hey.com__-Default" -> ["hey"].
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

  // ---- PID -> executable fallback (pass G) --------------------------------
  // Last resort for identities no desktop-entry metadata explains: resolve
  // /proc/<pid>/exe via ONE shared batched Process, then compare the
  // executable basename against entry metadata already in memory. Results
  // land in pidCache, which is REASSIGNED so bindings get real change
  // notifications; pendingPids deduplicates concurrent requests. No timers,
  // no polling, no per-window processes.
  property var pidCache: ({})
  property var pendingPids: ({})
  property int pidCacheRev: 0

  Process {
    id: exeProbe

    stdout: StdioCollector {
      onStreamFinished: root.finishExeBatch(this.text)
    }
  }

  function exeForPid(pid) {
    var p = parseInt(pid, 10)
    if (!p || p <= 0) return ""
    var v = root.pidCache[p]
    if (v !== undefined) return v // resolved basename or "" for unreadable
    if (root.pendingPids[p] === undefined) {
      root.pendingPids[p] = true
      root.flushExeQueue()
    }
    return ""
  }

  function flushExeQueue() {
    if (exeProbe.running) return
    var script = ""
    for (var key in root.pendingPids) {
      var pid = parseInt(key, 10)
      if (pid > 0)
        script += 'printf "%s\\t%s\\n" "' + pid + '" "$(readlink /proc/' + pid + '/exe 2>/dev/null)"; '
    }
    if (script.length === 0) { root.pendingPids = ({}); return }
    exeProbe.command = ["bash", "-c", script]
    exeProbe.running = true
  }

  function finishExeBatch(text) {
    var results = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var tab = line.indexOf("\t")
      if (tab <= 0) continue
      var exePath = line.slice(tab + 1)
      var slash = exePath.lastIndexOf("/")
      results[line.slice(0, tab)] = slash >= 0 ? exePath.slice(slash + 1) : exePath
    }
    var merged = Object.assign({}, root.pidCache)
    for (var key in root.pendingPids) {
      merged[key] = results[key] !== undefined ? results[key] : ""
      delete root.pendingPids[key]
    }
    root.pidCache = merged
    root.pidCacheRev++
    if (Object.keys(root.pendingPids).length > 0) Qt.callLater(root.flushExeQueue)
  }

  function entryByExe(exeName) {
    var want = String(exeName || "").toLowerCase()
    if (want.length === 0) return null
    var values = DesktopEntries.applications.values || []
    var matches = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (e.noDisplay) continue
      var cmdBase = root.execBasename(e).toLowerCase().replace(/\.[a-z]+$/, "")
      var idLower = String(e.id || "").toLowerCase().replace(/\.desktop$/, "")
      var sc = String(e.startupClass || "").toLowerCase()
      if (cmdBase === want || idLower === want || sc === want) {
        if (!matches.some(function(prev) { return prev.id === e.id })) matches.push(e)
      }
    }
    return root.uniqueEntryByIcon(matches)
  }

  // Returns an icon URL ("" when unresolved), synchronously. Called from
  // Image.source bindings. Reading applications.values here registers a
  // reactive dependency on the desktop-entry set: Quickshell populates it
  // ASYNCHRONOUSLY after startup, so every population change re-evaluates
  // this binding and unresolved identities retry against the fuller set.
  function iconFor(toplevel) {
    var identity = root.candidatesFor(toplevel)
    if (identity.names.length === 0) return ""

    var revision = root.desktopEntriesRevision
    var cached = root.iconCache[identity.key]
    // Reuse successful matches until the desktop-entry model changes.
    if (cached !== undefined && cached.entriesRevision === revision && cached.url !== "") return cached.url

    // Negative path. Register reactive dependencies on everything the
    // resolution depends on, then retry only once one of them actually
    // changed since the failed attempt (bounded work while they stream in).
    var entryCount = (DesktopEntries.applications.values || []).length
    var rev = revision + "/" + entryCount + "/" + root.pidCacheRev

    if (cached !== undefined && cached.rev === rev) return ""
    if (entryCount === 0) return ""

    var url = ""
    var entry = null
    var reason = ""
    var pid = toplevel && toplevel.lastIpcObject ? parseInt(toplevel.lastIpcObject.pid, 10) : 0
    var exeName = ""
    try {
      entry = root.resolveEntry(identity.names, function(passed) { reason = passed })
      if (!entry && pid > 0) {
        exeName = root.exeForPid(pid) // may enqueue; "" while pending
        if (exeName !== "") {
          entry = root.entryByExe(exeName)
          if (entry) reason = "pid-exe"
        }
      }
    } catch (err) {
      if (root.debugIcons) console.warn("[ncc.window-icons] resolve error:", err)
    }
    if (entry) url = root.iconSource(entry.icon)

    root.iconCache[identity.key] = {
      url: url,
      entryId: entry ? String(entry.id) : "",
      appName: entry ? String(entry.name || "") : "",
      names: identity.names,
      rev: rev,
      entriesRevision: revision
    }
    if (root.debugIcons) {
      console.warn("[ncc.window-icons] appId=" + identity.key.split("|")[0]
        + " class=" + identity.names.join("/")
        + " pid=" + pid
        + " exe=" + exeName
        + " matchedDesktopId=" + (entry ? String(entry.id) : "<none>")
        + " matchReason=" + (reason || "unresolved")
        + " icon=" + (entry ? String(entry.icon) : "<none>")
        + " source=" + url)
    }
    return url
  }

  // ---- Focused title formatting -------------------------------------------
  // "<title> – <application>" when the application name adds information.
  // The application display name comes from the desktop entry the icon
  // resolver already matched (so web apps report "WhatsApp"/"HEY", never
  // "Chromium"). Conservative dedup: if the raw window title already
  // contains the application name, it is shown unchanged — no rewriting of
  // arbitrary titles, and never "... – Mozilla Firefox – Mozilla Firefox".
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

  // ---- Settings panel ------------------------------------------------------
  // Popup contract expected by Bar.findPanelWidget: open()/close()/opened
  // on the widget root. Right-click anywhere on an entry toggles it; the
  // popup is a native qs.Ui PopupCard whose built-in HyprlandFocusGrab
  // (triggerMode defaults to "click") closes it whenever a click lands
  // outside the popup and the bar window.
  property bool settingsOpen: false
  readonly property bool opened: settingsOpen

  function open() {
    // The two popups must never coexist; releasing the overflow popup first
    // lets its onOpenChanged free the shared bar popout slot cleanly.
    overflowOpen = false
    syncDraftSettings()
    settingsOpen = true
  }

  function close() { settingsOpen = false }

  function togglePanel() {
    if (settingsOpen) close()
    else open()
  }

  // Panel-local drafts: slider movement writes ONLY these — one int write
  // plus a numeric label refresh per event. The injected settings object,
  // the layout math, icon geometry and icon effects are never touched while
  // dragging. Drafts are re-seeded from the committed settings on every
  // open, so values from an abandoned drag can never leak into the next
  // opening.
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

  // Applies ONE settled value to the local injected settings for instant
  // feedback, then persists through the native inline-settings write, after
  // which the shell's applySettingsDelta path patches every per-monitor
  // instance in place. Called once per gesture, never during movement.
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

  // Reset is ONE discrete operation: one settings-object update, one draft
  // re-sync, exactly one persistence call. Sliders follow the re-seeded
  // drafts; no per-slider commits run and no live-preview churn occurs.
  // Defaults are persisted as explicit values (never key deletion), with
  // every unrelated field of the widget entry preserved.
  function resetSettings() {
    var next = Object.assign({}, settings || {})
    for (var key in root.settingDefaults)
      next[key] = root.settingDefaults[key]
    settings = next
    syncDraftSettings()
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }


  // ---- Overflow popup --------------------------------------------------------
  // A second view of the windows already hidden by the width algorithm.
  property bool overflowOpen: false

  // Windows currently hidden behind "+N", in the underlying stable order:
  // stable-order candidates minus whatever is visible right now. Because the
  // focused-visibility swap places the focused window inside visibleWindows,
  // it can never appear twice. Derived from existing reactive state only —
  // no extra model, no extra work while closed beyond this small list.
  readonly property var hiddenWindows: {
    var out = []
    for (var i = 0; i < windowOrder.length; i++) {
      var t = windowOrder[i]
      if (windows.indexOf(t) !== -1 && visibleWindows.indexOf(t) === -1)
        out.push(t)
    }
    return out
  }

  // If enough space becomes available (or windows close), overflow ceases to
  // exist and the popup closes with it.
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

  // Dedicated close target so the PopupCard's native outside-click dismissal
  // routes to the overflow state instead of the settings state.
  QtObject {
    id: overflowOwner

    function close() { root.overflowOpen = false }
  }

  implicitWidth: vertical ? Style.bar.sizeVertical : row.implicitWidth
  implicitHeight: vertical ? column.implicitHeight : barSize

  // Cache invalidation rides on the reactive dependency iconFor() holds on
  // DesktopEntries.applications.values (the model's valuesChanged notify,
  // verified against the installed Quickshell): every entry-set change
  // re-evaluates the icon bindings. The revision counter also invalidates
  // cached matches when the model changes without changing its size.

  Item {
    anchors.fill: parent
    clip: true

    Row {
      id: row
      visible: !root.vertical
      spacing: root.entrySpacing

      Repeater {
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
      spacing: 2

      Repeater {
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
    readonly property bool showTitle: !root.vertical && focused && root.layout.titleWidth > 0
    readonly property real glyphSlot: root.vertical ? width : root.slotSize

    // Bar integration contracts (same pattern as qs.Ui WidgetButton):
    // - interactive: transient empty layout slots must never become click
    //   targets or react to the pointer.
    // - tooltipHovered: read by Bar.targetTooltipHovered()/its watchdog;
    //   gating on !settingsOpen also suppresses tooltips while the popup
    //   is open instead of stacking UI over it.
    readonly property bool interactive: win !== null
    readonly property bool tooltipHovered: entry.interactive && !root.settingsOpen && area.containsMouse

    // Ensures the identity resolution ran (cache warm) before formatting;
    // also registers the same reactive deps as the icon so a late desktop-
    // entry population refreshes the app-name suffix too.
    readonly property string displayTitle: {
      if (!win) return ""
      root.iconFor(win)
      return root.formatTitle(win)
    }

    // Single action path shared by the bar's central left-click dispatcher
    // (ModuleSlot.modulePointer -> pressModuleClickTarget) and this entry's
    // own MouseArea, which is the direct path for middle/right buttons and
    // the fallback when no target is clickable.
    function triggerPress(button) {
      if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(entry)
      if (!entry.win || !entry.win.wayland) return
      if (button === Qt.MiddleButton) {
        entry.win.wayland.close()
      } else if (button === Qt.RightButton) {
        root.togglePanel()
      } else {
        // Any interaction with our own entries also dismisses the settings
        // popup, so it never lingers over normal use.
        if (root.settingsOpen) root.close()
        entry.win.wayland.activate()
      }
    }

    // Register as a bar click target so ModuleSlot's topmost pointer area
    // resolves the pointing-hand cursor over this whole entry and forwards
    // left clicks here. The bar is injected by injectProps after delegates
    // complete, so registration re-syncs whenever it appears.
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

    // Icon slot: resolved desktop-entry icon, or the slice-1 glyph fallback.
    Item {
      width: entry.glyphSlot
      height: parent.height
      opacity: entry.focused ? 1.0 : 0.55

      readonly property string iconUrl: entry.win ? root.iconFor(entry.win) : ""

      Image {
        id: appIcon
        anchors.centerIn: parent
        visible: parent.iconUrl.length > 0
        width: root.configuredIconSize
        height: root.configuredIconSize
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        // Decode at physical pixels — a logical-size decode leaves PNG icons
        // upscaled and blurry on HiDPI displays (same as the menu's rows).
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        source: parent.iconUrl.length > 0 ? parent.iconUrl : ""
        // Saturation applies to application icons only. At 100% the effect
        // layer stays disabled so there is no extra GPU cost.
        layer.enabled: root.saturationEffect !== 0
        layer.smooth: true
        layer.effect: MultiEffect {
          saturation: root.saturationEffect
        }
      }

      Text {
        anchors.fill: parent
        visible: parent.iconUrl.length === 0 || appIcon.status === Image.Error
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: root.glyphFor(entry.win)
        color: Color.foreground
        font.pixelSize: Style.font.body
      }
    }

    // Focused title viewport: fixed width from the layout budget (never the
    // text's implicit width — no feedback into root sizing), clipped, and
    // the only marquee in the widget. Inactive entries never enter here
    // because showTitle is focused-only.
    Item {
      id: titleClip
      x: entry.glyphSlot
      width: parent.width - entry.glyphSlot
      height: parent.height
      clip: true
      visible: entry.showTitle

      readonly property bool overflowing: titleText.contentWidth > width + 1

      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        x: 0
        textFormat: Text.PlainText
        text: entry.displayTitle
        color: Color.foreground
        font.pixelSize: Style.font.body
      }

      SequentialAnimation {
        id: marquee

        running: !root.vertical && entry.showTitle && titleClip.overflowing && !entry.hovered
        loops: Animation.Infinite

        PropertyAction { target: titleText; property: "x"; value: 0 }
        PauseAnimation { duration: root.marqueeStartPause }
        NumberAnimation {
          target: titleText
          property: "x"
          to: -(titleText.contentWidth - titleClip.width)
          duration: Math.max(300, Math.round((titleText.contentWidth - titleClip.width) * 1000 / root.marqueeSpeed))
        }
        PauseAnimation { duration: root.marqueeEndPause }
        PropertyAction { target: titleText; property: "x"; value: 0 }
        PauseAnimation { duration: root.marqueeCyclePause }

        // Reset cleanly whenever the animation stops (focus lost, text now
        // fits, vertical mode) so a stale offset never lingers.
        onRunningChanged: if (!running) titleText.x = 0
      }
    }

    MouseArea {
      id: area
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      enabled: entry.interactive
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      // Left clicks normally arrive through the bar's central dispatcher,
      // which consumes them once a target is found; this handler is then a
      // no-op fallback for transient unregistered states and the direct
      // path for middle/right, which modulePointer does not accept.
      onClicked: function(mouse) { entry.triggerPress(mouse.button) }

      // Bar-hosted tooltip: inactive entries are icon-only, so the full
      // formatted title is new information there. The active entry always
      // shows its title/marquee — that marquee is already the mechanism for
      // reading overflowing text, so it never gets a redundant tooltip.
      // showTooltip itself refuses while settings are open (see
      // tooltipHovered), so nothing stacks over the popup.
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

    // Click-target registration keeps the pointing-hand cursor consistent
    // over the indicator. Left click toggles the hidden-windows popup; right
    // click keeps opening settings. Middle click is intentionally a no-op.
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

  // ---- Settings popup --------------------------------------------------------
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
        text: "WINDOW SETTINGS"
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
        label: "Icon size"
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
        label: "Icon saturation"
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
        label: "Maximum widget width"
        suffix: "px"
        minimum: 160
        maximum: 1000
        step: 10
        currentValue: root.draftMaxWidth
        onCommitted: function(value) {
          root.draftMaxWidth = value
          root.saveSetting("maxWidth", value)
        }
      }

      SettingSlider {
        label: "Focused title width"
        suffix: "px"
        minimum: 40
        maximum: 400
        step: 10
        currentValue: root.draftTitleWidth
        onCommitted: function(value) {
          root.draftTitleWidth = value
          root.saveSetting("focusedTitleMaxWidth", value)
        }
      }

      SettingSlider {
        label: "Spacing"
        suffix: "px"
        minimum: 2
        maximum: 12
        step: 1
        currentValue: root.draftSpacing
        onCommitted: function(value) {
          root.draftSpacing = value
          root.saveSetting("spacing", value)
        }
      }

      Button {
        width: settingsColumn.width
        text: "Reset to defaults"
        onClicked: root.resetSettings()
      }
    }
  }

  // ---- Overflow popup --------------------------------------------------------
  // Lists ONLY the windows currently hidden behind "+N", in stable order.
  // Anchored to the widget like the settings popup; the two popups are
  // mutually exclusive by construction (open()/toggleOverflow()) and share
  // the bar's popout coordination for any remaining path.
  PopupCard {
    id: overflowPopup
    anchorItem: root
    bar: root.bar
    owner: overflowOwner
    open: root.overflowOpen
    contentWidth: fittedContentWidth(Style.space(260))
    contentHeight: fittedContentHeight(overflowColumn.implicitHeight)

    Column {
      id: overflowColumn
      anchors.fill: parent
      spacing: Style.space(4)

      Repeater {
        model: root.hiddenWindows
        delegate: OverflowRow {}
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

    // Icon and title reuse the existing resolver/formatter — no new
    // resolution architecture.
    Item {
      id: rowIconSlot
      width: Style.space(24)
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Image {
        id: overflowIcon
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
        visible: overflowRow.iconUrl.length === 0 || overflowIcon.status === Image.Error
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
          // The list updates reactively once the window closes; the popup
          // stays open unless nothing remains hidden.
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
      // Movement drives only the slider's own liveValue (knob position and
      // the numeric label above). The widget is touched exactly once, here.
      onReleased: function(value) { sliderSetting.committed(Math.round(value)) }
    }
  }
}

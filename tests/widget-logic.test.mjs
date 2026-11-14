import assert from "node:assert/strict"
import fs from "node:fs"

const source = fs.readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8")

function extractFunction(name) {
  const start = source.indexOf(`  function ${name}(`)
  assert.notEqual(start, -1, `Missing QML function: ${name}`)
  const brace = source.indexOf("{", start)
  let depth = 0
  let end = brace

  for (; end < source.length; end++) {
    if (source[end] === "{") depth++
    else if (source[end] === "}" && --depth === 0) break
  }

  return source
    .slice(start + 2, end + 1)
    .replace(`function ${name}`, "function")
}

function bind(root, name) {
  root[name] = Function("root", `return (${extractFunction(name)})`)(root)
}

{
  const root = {
    vertical: false,
    verticalMaxEntries: 10,
    slotSize: 28,
    indicatorSlot: 32,
    entrySpacing: 4,
    maxWidth: 160,
    maxTitleWidth: 120
  }
  bind(root, "computeLayout")

  for (let count = 0; count <= 100; count++) {
    const layout = root.computeLayout(count)
    const slots = layout.visibleCount + (layout.hidden > 0 ? 1 : 0)
    const width = layout.visibleCount * root.slotSize
      + (layout.hidden > 0 ? root.indicatorSlot : 0)
      + Math.max(0, slots - 1) * root.entrySpacing
      + layout.titleWidth

    assert.ok(width <= root.maxWidth, `layout exceeds maxWidth for ${count} windows`)
  }
}

{
  const [a, b, hidden, c] = [{}, {}, {}, {}]
  const root = { windowOrder: [a, b, hidden, c] }
  bind(root, "moveWindowRelative")

  root.moveWindowRelative(c, a, false)
  assert.deepEqual(root.windowOrder, [c, a, b, hidden])

  root.moveWindowRelative(c, b, true)
  assert.deepEqual(root.windowOrder, [a, b, c, hidden])
}

{
  const root = {
    webAppStopWords: "|www|com|net|org|gov|edu|int|io|co|dev|app|web|mail|html|htm|default|profile|index|login|auth|mobile|new|home|main|site|"
  }
  for (const name of [
    "normalizeCandidate",
    "isWebAppStopWord",
    "candidateSegments",
    "fallbackIconNames"
  ]) bind(root, name)

  assert.deepEqual(
    root.fallbackIconNames(
      { lastIpcObject: { initialTitle: "Chromium" } },
      ["chrome-chatgpt.com__-Default"]
    ),
    ["chrome-chatgpt.com__-Default", "chatgpt", "Chromium"]
  )

  assert.deepEqual(
    root.fallbackIconNames(
      { lastIpcObject: { initialTitle: "foot" } },
      ["org.omarchy.agent"]
    ),
    ["org.omarchy.agent", "omarchy", "foot"]
  )
}

const catalogs = ["en", "es"].map(locale =>
  JSON.parse(fs.readFileSync(new URL(`../i18n/${locale}.json`, import.meta.url), "utf8"))
)
assert.deepEqual(Object.keys(catalogs[1]).sort(), Object.keys(catalogs[0]).sort())

console.log("widget logic tests passed")

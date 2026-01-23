import {
  CliRenderer,
  createCliRenderer,
  CodeRenderable,
  BoxRenderable,
  TextRenderable,
  type ParsedKey,
  ScrollBoxRenderable,
  LineNumberRenderable,
  type OnHighlightCallback,
  type SimpleHighlight,
  RGBA,
} from "../index"
import { setupCommonDemoKeys } from "./lib/standalone-keys"
import { parseColor } from "../lib/RGBA"
import { SyntaxStyle } from "../syntax-style"

// Code example with hex color codes
const codeWithColors = `// Theme colors
const theme = {
  primary: "#3B82F6",     // Blue
  secondary: "#10B981",   // Green
  accent: "#F59E0B",      // Amber
  danger: "#EF4444",      // Red
  warning: "#F97316",     // Orange
  info: "#06B6D4",        // Cyan
  dark: "#1F2937",        // Dark gray
  light: "#F3F4F6",       // Light gray
}

// Short hex codes also work
const shortColors = {
  red: "#F00",
  green: "#0F0",
  blue: "#00F",
  yellow: "#FF0",
  cyan: "#0FF",
  magenta: "#F0F",
}

// RGBA colors with alpha
const transparent = {
  overlay: "#00000080",   // 50% transparent black
  highlight: "#FFFF0040", // 25% transparent yellow
  shadow: "#0000001A",    // 10% transparent black
}

// CSS variables example
const cssVars = \`
  --color-primary: #7C3AED;
  --color-success: #22C55E;
  --color-error: #DC2626;
  --color-warning: #EAB308;
  --background: #0F172A;
  --foreground: #E2E8F0;
\`;

// Palette generation
function generatePalette(base: string) {
  // These would be calculated from the base color
  return {
    50: "#F0F9FF",
    100: "#E0F2FE",
    200: "#BAE6FD",
    300: "#7DD3FC",
    400: "#38BDF8",
    500: "#0EA5E9",
    600: "#0284C7",
    700: "#0369A1",
    800: "#075985",
    900: "#0C4A6E",
  }
}`

// Find hex color codes in text (#RGB, #RGBA, #RRGGBB, #RRGGBBAA formats)
function findColorCodes(text: string): Array<{ start: number; end: number; color: string }> {
  const result: Array<{ start: number; end: number; color: string }> = []
  const regex = /#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b/g
  let match

  while ((match = regex.exec(text)) !== null) {
    result.push({
      start: match.index,
      end: match.index + match[0].length,
      color: match[0],
    })
  }

  return result
}

function hexToRgb(hex: string): { r: number; g: number; b: number; a: number } {
  const color = hex.replace("#", "")
  const hasAlpha = color.length === 4 || color.length === 8

  const expanded =
    color.length <= 4
      ? color
          .split("")
          .map((c) => c + c)
          .join("")
      : color

  const r = parseInt(expanded.slice(0, 2), 16)
  const g = parseInt(expanded.slice(2, 4), 16)
  const b = parseInt(expanded.slice(4, 6), 16)
  const a = hasAlpha ? parseInt(expanded.slice(6, 8), 16) / 255 : 1

  return { r, g, b, a }
}

function blendColors(
  fg: { r: number; g: number; b: number; a: number },
  bg: { r: number; g: number; b: number },
): { r: number; g: number; b: number } {
  return {
    r: Math.round(fg.r * fg.a + bg.r * (1 - fg.a)),
    g: Math.round(fg.g * fg.a + bg.g * (1 - fg.a)),
    b: Math.round(fg.b * fg.a + bg.b * (1 - fg.a)),
  }
}

function getContrastColor(color: { r: number; g: number; b: number }): { r: number; g: number; b: number } {
  const luminance = (0.299 * color.r + 0.587 * color.g + 0.114 * color.b) / 255
  return luminance > 0.5 ? { r: 0, g: 0, b: 0 } : { r: 255, g: 255, b: 255 }
}

// Register color styles upfront for all hex codes found in content
function registerColorStyles(
  syntaxStyle: SyntaxStyle,
  content: string,
  backgroundColor: { r: number; g: number; b: number },
): void {
  const colors = findColorCodes(content)
  const registered = new Set<string>()

  for (const pos of colors) {
    const styleName = `color.${pos.color.replace("#", "")}`
    if (registered.has(styleName)) continue

    const rgba = hexToRgb(pos.color)
    const blended = blendColors(rgba, backgroundColor)
    const fg = getContrastColor(blended)

    syntaxStyle.registerStyle(styleName, {
      fg: RGBA.fromInts(fg.r, fg.g, fg.b),
      bg: RGBA.fromInts(blended.r, blended.g, blended.b),
    })
    registered.add(styleName)
  }
}

function createColorCodeHighlighter(): OnHighlightCallback {
  return (highlights: SimpleHighlight[], context) => {
    const colors = findColorCodes(context.content)

    if (colors.length === 0) {
      return highlights
    }

    // Just add color highlights on top of existing tree-sitter highlights
    for (const pos of colors) {
      const styleName = `color.${pos.color.replace("#", "")}`
      highlights.push([pos.start, pos.end, styleName, {}])
    }

    return highlights
  }
}

let renderer: CliRenderer | null = null
let keyboardHandler: ((key: ParsedKey) => void) | null = null
let parentContainer: BoxRenderable | null = null
let codeScrollBox: ScrollBoxRenderable | null = null
let codeDisplay: CodeRenderable | null = null
let codeWithLineNumbers: LineNumberRenderable | null = null
let infoText: TextRenderable | null = null
let syntaxStyle: SyntaxStyle | null = null
let colorHighlightEnabled = true

export async function run(rendererInstance: CliRenderer): Promise<void> {
  renderer = rendererInstance
  renderer.start()
  renderer.setBackgroundColor("#0D1117")

  // Background color for blending alpha colors
  const bgColor = { r: 13, g: 17, b: 23 } // #0D1117

  parentContainer = new BoxRenderable(renderer, {
    id: "parent-container",
    zIndex: 10,
    padding: 1,
  })
  renderer.root.add(parentContainer)

  const titleBox = new BoxRenderable(renderer, {
    id: "title-box",
    height: 3,
    borderStyle: "double",
    borderColor: "#4ECDC4",
    backgroundColor: "#0D1117",
    title: "Color Code Highlighting Demo",
    titleAlignment: "center",
    border: true,
  })
  parentContainer.add(titleBox)

  const instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    content: "ESC to return | C: Toggle color highlighting",
    fg: "#888888",
  })
  titleBox.add(instructionsText)

  codeScrollBox = new ScrollBoxRenderable(renderer, {
    id: "code-scroll-box",
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#0D1117",
    title: "TypeScript - Hex Colors",
    titleAlignment: "left",
    border: true,
    scrollY: true,
    scrollX: false,
    flexGrow: 1,
    flexShrink: 1,
  })
  parentContainer.add(codeScrollBox)

  // Create syntax style similar to GitHub Dark theme
  syntaxStyle = SyntaxStyle.fromStyles({
    keyword: { fg: parseColor("#FF7B72"), bold: true },
    "keyword.import": { fg: parseColor("#FF7B72"), bold: true },
    string: { fg: parseColor("#A5D6FF") },
    comment: { fg: parseColor("#8B949E"), italic: true },
    number: { fg: parseColor("#79C0FF") },
    boolean: { fg: parseColor("#79C0FF") },
    constant: { fg: parseColor("#79C0FF") },
    function: { fg: parseColor("#D2A8FF") },
    "function.call": { fg: parseColor("#D2A8FF") },
    constructor: { fg: parseColor("#FFA657") },
    type: { fg: parseColor("#FFA657") },
    operator: { fg: parseColor("#FF7B72") },
    variable: { fg: parseColor("#E6EDF3") },
    "variable.member": { fg: parseColor("#79C0FF") },
    property: { fg: parseColor("#79C0FF") },
    bracket: { fg: parseColor("#F0F6FC") },
    "punctuation.bracket": { fg: parseColor("#F0F6FC") },
    "punctuation.delimiter": { fg: parseColor("#C9D1D9") },
    punctuation: { fg: parseColor("#F0F6FC") },
    default: { fg: parseColor("#E6EDF3") },
  })

  // Register color styles upfront to avoid repeated FFI calls during highlighting
  registerColorStyles(syntaxStyle, codeWithColors, bgColor)

  // Create color highlighter (styles already registered)
  const colorHighlighter = createColorCodeHighlighter()

  // Create code display with color highlighting callback
  codeDisplay = new CodeRenderable(renderer, {
    id: "code-display",
    content: codeWithColors,
    filetype: "typescript",
    syntaxStyle,
    selectable: true,
    selectionBg: "#264F78",
    selectionFg: "#FFFFFF",
    width: "100%",
    onHighlight: colorHighlighter,
  })

  codeWithLineNumbers = new LineNumberRenderable(renderer, {
    id: "code-with-lines",
    target: codeDisplay,
    minWidth: 3,
    paddingRight: 1,
    fg: "#6b7280",
    bg: "#161b22",
    width: "100%",
  })

  codeScrollBox.add(codeWithLineNumbers)

  infoText = new TextRenderable(renderer, {
    id: "info-display",
    content: `Color highlighting: ${colorHighlightEnabled ? "ON" : "OFF"} | Hex colors shown with their actual color as background`,
    fg: "#A5D6FF",
    wrapMode: "word",
    flexShrink: 0,
  })
  parentContainer.add(infoText)

  const updateInfoText = () => {
    if (infoText) {
      infoText.content = `Color highlighting: ${colorHighlightEnabled ? "ON" : "OFF"} | Hex colors shown with their actual color as background`
    }
  }

  keyboardHandler = (key: ParsedKey) => {
    if (key.name === "c" && !key.ctrl && !key.meta) {
      // Toggle color highlighting
      colorHighlightEnabled = !colorHighlightEnabled
      if (codeDisplay) {
        codeDisplay.onHighlight = colorHighlightEnabled ? colorHighlighter : undefined
      }
      updateInfoText()
    }
  }

  rendererInstance.keyInput.on("keypress", keyboardHandler)
}

export function destroy(rendererInstance: CliRenderer): void {
  if (keyboardHandler) {
    rendererInstance.keyInput.off("keypress", keyboardHandler)
    keyboardHandler = null
  }

  parentContainer?.destroy()
  parentContainer = null
  codeScrollBox = null
  codeDisplay = null
  codeWithLineNumbers = null
  infoText = null
  syntaxStyle = null

  renderer = null
}

if (import.meta.main) {
  const renderer = await createCliRenderer({
    exitOnCtrlC: true,
    targetFps: 60,
  })
  run(renderer)
  setupCommonDemoKeys(renderer)
}

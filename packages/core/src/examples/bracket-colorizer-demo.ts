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
  type HighlightContext,
} from "../index"
import { setupCommonDemoKeys } from "./lib/standalone-keys"
import { parseColor } from "../lib/RGBA"
import { SyntaxStyle } from "../syntax-style"

// Sample code with lots of nested brackets
const sampleCode = `import { useState, useEffect, useCallback, useMemo } from 'react';

interface Config {
  settings: {
    theme: {
      colors: {
        primary: string;
        secondary: string;
      };
      fonts: {
        heading: string;
        body: string;
      };
    };
    features: {
      enabled: boolean[];
      options: Map<string, { value: number; label: string }>;
    };
  };
}

type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P];
};

const processData = (items: Array<{ id: number; data: { nested: { value: string }[] } }>) => {
  return items.map((item) => ({
    ...item,
    data: {
      ...item.data,
      nested: item.data.nested.filter((n) => n.value !== ''),
    },
  }));
};

function Component({ config }: { config: Config }) {
  const [state, setState] = useState<{ count: number; items: string[] }>({
    count: 0,
    items: [],
  });

  const computed = useMemo(() => {
    const result = {
      total: state.items.reduce((acc, item) => {
        return acc + (item.length > 0 ? 1 : 0);
      }, 0),
      filtered: state.items.filter((item) => {
        return item.trim().length > 0;
      }),
    };
    return result;
  }, [state.items]);

  const handleClick = useCallback((event: { target: { value: string } }) => {
    const newValue = event.target.value;
    setState((prev) => ({
      ...prev,
      items: [...prev.items, newValue],
      count: prev.count + 1,
    }));
  }, []);

  useEffect(() => {
    const subscription = {
      unsubscribe: () => {
        console.log('Cleaning up');
      },
    };

    const interval = setInterval(() => {
      setState((prev) => ({ ...prev, count: prev.count + 1 }));
    }, 1000);

    return () => {
      subscription.unsubscribe();
      clearInterval(interval);
    };
  }, []);

  return (
    <div className={config.settings.theme.colors.primary}>
      <header>
        <h1>{state.count}</h1>
      </header>
      <main>
        <ul>
          {computed.filtered.map((item, index) => (
            <li key={index} onClick={() => handleClick({ target: { value: item } })}>
              {item}
            </li>
          ))}
        </ul>
      </main>
      <footer>
        <p>Total: {computed.total}</p>
      </footer>
    </div>
  );
}

// Deeply nested array/object literals
const matrix = [
  [[1, 2], [3, 4]],
  [[5, 6], [7, 8]],
  [
    [9, 10],
    [11, 12],
  ],
];

const nested = {
  a: {
    b: {
      c: {
        d: {
          e: 'deep',
        },
      },
    },
  },
};

export { Component, processData, matrix, nested };
`

// Bracket types and their pairs
const BRACKET_PAIRS: Record<string, string> = {
  "(": ")",
  "[": "]",
  "{": "}",
  "<": ">",
}

const OPENING_BRACKETS = new Set(Object.keys(BRACKET_PAIRS))
const CLOSING_BRACKETS = new Set(Object.values(BRACKET_PAIRS))

// Color cycle for bracket depth (6 distinct colors)
const BRACKET_DEPTH_COLORS = [
  "bracket.depth0", // Gold
  "bracket.depth1", // Magenta
  "bracket.depth2", // Cyan
  "bracket.depth3", // Green
  "bracket.depth4", // Orange
  "bracket.depth5", // Blue
]

interface BracketMatch {
  openPos: number
  closePos: number
  char: string
  depth: number
}

// Find and match all bracket pairs in content
function findBracketPairs(content: string): BracketMatch[] {
  const matches: BracketMatch[] = []
  const stacks: Map<string, Array<{ pos: number; depth: number }>> = new Map()

  // Initialize stacks for each bracket type
  for (const open of OPENING_BRACKETS) {
    stacks.set(open, [])
  }

  // Track depth per bracket type
  const depths: Map<string, number> = new Map()
  for (const open of OPENING_BRACKETS) {
    depths.set(open, 0)
  }

  // Track if we're inside a string or comment (simple heuristic)
  let inString: string | null = null
  let inLineComment = false
  let inBlockComment = false

  for (let i = 0; i < content.length; i++) {
    const char = content[i]
    const prevChar = i > 0 ? content[i - 1] : ""
    const nextChar = i < content.length - 1 ? content[i + 1] : ""

    // Handle newlines (reset line comment)
    if (char === "\n") {
      inLineComment = false
      continue
    }

    // Skip if in line comment
    if (inLineComment) continue

    // Handle block comment start/end
    if (!inString && char === "/" && nextChar === "*") {
      inBlockComment = true
      continue
    }
    if (inBlockComment && char === "*" && nextChar === "/") {
      inBlockComment = false
      i++ // Skip the /
      continue
    }
    if (inBlockComment) continue

    // Handle line comment start
    if (!inString && char === "/" && nextChar === "/") {
      inLineComment = true
      continue
    }

    // Handle string boundaries
    if (!inString && (char === '"' || char === "'" || char === "`")) {
      inString = char
      continue
    }
    if (inString && char === inString && prevChar !== "\\") {
      inString = null
      continue
    }
    if (inString) continue

    // Handle brackets
    if (OPENING_BRACKETS.has(char)) {
      const stack = stacks.get(char)!
      const depth = depths.get(char)!
      stack.push({ pos: i, depth })
      depths.set(char, depth + 1)
    } else if (CLOSING_BRACKETS.has(char)) {
      // Find the matching opening bracket
      const openChar = Object.entries(BRACKET_PAIRS).find(([_, close]) => close === char)?.[0]
      if (openChar) {
        const stack = stacks.get(openChar)!
        if (stack.length > 0) {
          const open = stack.pop()!
          depths.set(openChar, depths.get(openChar)! - 1)
          matches.push({
            openPos: open.pos,
            closePos: i,
            char: openChar,
            depth: open.depth,
          })
        }
      }
    }
  }

  return matches
}

// Track which bracket types are enabled
type BracketType = "(" | "[" | "{" | "<"
const ALL_BRACKET_TYPES: BracketType[] = ["(", "[", "{", "<"]

// Create the bracket colorizer callback
function createBracketColorizer(enabledTypes: Set<BracketType>): OnHighlightCallback {
  return (highlights: SimpleHighlight[], context: HighlightContext) => {
    // Use context.content to find bracket pairs
    const bracketPairs = findBracketPairs(context.content)

    if (bracketPairs.length === 0) {
      return highlights
    }

    // Add bracket highlights based on depth
    for (const pair of bracketPairs) {
      // Skip if this bracket type is not enabled
      if (!enabledTypes.has(pair.char as BracketType)) {
        continue
      }

      // Get color based on depth (cycles through colors)
      const colorIndex = pair.depth % BRACKET_DEPTH_COLORS.length
      const styleName = BRACKET_DEPTH_COLORS[colorIndex]

      // Add highlight for opening bracket
      highlights.push([pair.openPos, pair.openPos + 1, styleName, {}])

      // Add highlight for closing bracket
      const closeChar = BRACKET_PAIRS[pair.char]
      highlights.push([pair.closePos, pair.closePos + 1, styleName, {}])
    }

    return highlights
  }
}

// Count brackets by type and depth
function countBrackets(content: string): { total: number; byType: Map<string, number>; maxDepth: number } {
  const pairs = findBracketPairs(content)
  const byType = new Map<string, number>()
  let maxDepth = 0

  for (const pair of pairs) {
    byType.set(pair.char, (byType.get(pair.char) || 0) + 1)
    maxDepth = Math.max(maxDepth, pair.depth + 1)
  }

  return { total: pairs.length, byType, maxDepth }
}

let renderer: CliRenderer | null = null
let keyboardHandler: ((key: ParsedKey) => void) | null = null
let parentContainer: BoxRenderable | null = null
let codeScrollBox: ScrollBoxRenderable | null = null
let codeDisplay: CodeRenderable | null = null
let codeWithLineNumbers: LineNumberRenderable | null = null
let infoText: TextRenderable | null = null
let statsText: TextRenderable | null = null
let syntaxStyle: SyntaxStyle | null = null

// Track which bracket types are enabled
let enabledTypes = new Set<BracketType>(ALL_BRACKET_TYPES)
let bracketColorizerEnabled = true

function updateHighlighter() {
  if (codeDisplay) {
    if (bracketColorizerEnabled && enabledTypes.size > 0) {
      codeDisplay.onHighlight = createBracketColorizer(enabledTypes)
    } else {
      codeDisplay.onHighlight = undefined
    }
  }
}

function updateInfoText() {
  if (infoText) {
    const enabledList =
      Array.from(enabledTypes)
        .map((t) => `${t}${BRACKET_PAIRS[t]}`)
        .join(" ") || "none"
    infoText.content = `Bracket colorizer: ${bracketColorizerEnabled ? "ON" : "OFF"} | Enabled: ${enabledList}`
  }
}

function updateStatsText() {
  if (statsText) {
    const stats = countBrackets(sampleCode)
    const parts: string[] = [`Total pairs: ${stats.total}`, `Max depth: ${stats.maxDepth}`]

    for (const [type, count] of stats.byType) {
      const enabled = enabledTypes.has(type as BracketType) ? "" : " (off)"
      parts.push(`${type}${BRACKET_PAIRS[type]}: ${count}${enabled}`)
    }

    statsText.content = parts.join(" | ")
  }
}

export async function run(rendererInstance: CliRenderer): Promise<void> {
  renderer = rendererInstance
  renderer.start()
  renderer.setBackgroundColor("#0D1117")

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
    borderColor: "#A855F7",
    backgroundColor: "#0D1117",
    title: "Bracket Pair Colorizer Demo",
    titleAlignment: "center",
    border: true,
  })
  parentContainer.add(titleBox)

  const instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    content: "ESC return | B toggle all | 1:() 2:[] 3:{} 4:<> | Uses context.content to match pairs",
    fg: "#888888",
  })
  titleBox.add(instructionsText)

  // Color legend
  const legendBox = new BoxRenderable(renderer, {
    id: "legend-box",
    height: 3,
    border: true,
    borderStyle: "single",
    borderColor: "#475569",
    backgroundColor: "#161B22",
    title: "Depth Colors (cycles after 6)",
    titleAlignment: "left",
    flexShrink: 0,
  })
  parentContainer.add(legendBox)

  const legendText = new TextRenderable(renderer, {
    id: "legend-text",
    content: "0:Gold  1:Magenta  2:Cyan  3:Green  4:Orange  5:Blue",
    fg: "#A5D6FF",
  })
  legendBox.add(legendText)

  codeScrollBox = new ScrollBoxRenderable(renderer, {
    id: "code-scroll-box",
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#0D1117",
    title: "TypeScript - Nested Brackets",
    titleAlignment: "left",
    border: true,
    scrollY: true,
    scrollX: false,
    flexGrow: 1,
    flexShrink: 1,
  })
  parentContainer.add(codeScrollBox)

  // Create syntax style with bracket depth colors pre-registered
  syntaxStyle = SyntaxStyle.fromStyles({
    // Base syntax colors (GitHub Dark theme)
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

    // Bracket depth colors - registered upfront, NOT in the callback
    "bracket.depth0": { fg: parseColor("#FFD700"), bold: true }, // Gold
    "bracket.depth1": { fg: parseColor("#FF00FF"), bold: true }, // Magenta
    "bracket.depth2": { fg: parseColor("#00FFFF"), bold: true }, // Cyan
    "bracket.depth3": { fg: parseColor("#00FF00"), bold: true }, // Green
    "bracket.depth4": { fg: parseColor("#FFA500"), bold: true }, // Orange
    "bracket.depth5": { fg: parseColor("#6495ED"), bold: true }, // Cornflower Blue
  })

  codeDisplay = new CodeRenderable(renderer, {
    id: "code-display",
    content: sampleCode,
    filetype: "typescript",
    syntaxStyle,
    selectable: true,
    selectionBg: "#264F78",
    selectionFg: "#FFFFFF",
    width: "100%",
    onHighlight: createBracketColorizer(enabledTypes),
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

  // Stats display
  statsText = new TextRenderable(renderer, {
    id: "stats-display",
    content: "",
    fg: "#94A3B8",
    wrapMode: "word",
    flexShrink: 0,
  })
  parentContainer.add(statsText)

  infoText = new TextRenderable(renderer, {
    id: "info-display",
    content: "",
    fg: "#A5D6FF",
    wrapMode: "word",
    flexShrink: 0,
  })
  parentContainer.add(infoText)

  updateInfoText()
  updateStatsText()

  keyboardHandler = (key: ParsedKey) => {
    // B to toggle all bracket colorizing
    if (key.name === "b" && !key.ctrl && !key.meta) {
      bracketColorizerEnabled = !bracketColorizerEnabled
      updateHighlighter()
      updateInfoText()
      return
    }

    // 1-4 to toggle individual bracket types
    const typeIndex = parseInt(key.raw || "", 10) - 1
    if (typeIndex >= 0 && typeIndex < ALL_BRACKET_TYPES.length) {
      const bracketType = ALL_BRACKET_TYPES[typeIndex]
      if (enabledTypes.has(bracketType)) {
        enabledTypes.delete(bracketType)
      } else {
        enabledTypes.add(bracketType)
      }
      updateHighlighter()
      updateInfoText()
      updateStatsText()
      return
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
  statsText = null
  syntaxStyle = null

  // Reset state
  enabledTypes = new Set<BracketType>(ALL_BRACKET_TYPES)
  bracketColorizerEnabled = true

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

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

// Sample code with various lint patterns
const sampleCode = `import { useState, useEffect } from 'react';
import { fetchData } from './api';

// TODO: Add proper error boundaries
// FIXME: Memory leak when component unmounts
// HACK: Workaround for React 18 strict mode
// NOTE: This component requires the UserContext provider
// XXX: Remove this before production
// DEPRECATED: Use NewUserList instead

interface User {
  id: number;
  name: string;
  email: string;
  // TODO: Add role field
}

export function UserList() {
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(false);
  
  // FIXME: This doesn't handle race conditions
  useEffect(() => {
    let cancelled = false;
    
    const load = async () => {
      setLoading(true);
      try {
        // TODO: Add pagination support
        const data = await fetchData('/users');
        if (!cancelled) {
          setUsers(data);
        }
      } catch (err) {
        // HACK: Silently ignore errors for now
        console.error(err);
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    };
    
    load();
    
    // NOTE: Cleanup function prevents state updates after unmount
    return () => { cancelled = true; };
  }, []);

  // XXX: Temporary sorting - remove when API supports it
  const sortedUsers = [...users].sort((a, b) => a.name.localeCompare(b.name));

  if (loading) {
    return <div>Loading...</div>;
  }

  // DEPRECATED: Use UserCard component instead of inline JSX
  return (
    <ul>
      {sortedUsers.map(user => (
        <li key={user.id}>
          {/* TODO: Add avatar */}
          <span>{user.name}</span>
          {/* FIXME: Email should be a link */}
          <span>{user.email}</span>
        </li>
      ))}
    </ul>
  );
}

// HACK: Export for testing only
export const __testing = { sortUsers: (users: User[]) => users };
`

// Lint pattern definitions
interface LintPattern {
  keyword: string
  styleName: string
  description: string
}

const LINT_PATTERNS: LintPattern[] = [
  { keyword: "TODO", styleName: "lint.todo", description: "Task to be done" },
  { keyword: "FIXME", styleName: "lint.fixme", description: "Bug or issue to fix" },
  { keyword: "HACK", styleName: "lint.hack", description: "Workaround or hack" },
  { keyword: "NOTE", styleName: "lint.note", description: "Important note" },
  { keyword: "XXX", styleName: "lint.xxx", description: "Needs attention" },
  { keyword: "DEPRECATED", styleName: "lint.deprecated", description: "Deprecated code" },
]

// Supported file types for lint highlighting
const SUPPORTED_FILETYPES = new Set([
  "typescript",
  "javascript",
  "tsx",
  "jsx",
  "python",
  "rust",
  "go",
  "c",
  "cpp",
  "java",
  "ruby",
  "php",
  "swift",
  "kotlin",
  "scala",
  "lua",
  "bash",
  "sh",
  "css",
  "scss",
  "html",
])

interface LintMatch {
  start: number
  end: number
  keyword: string
  styleName: string
  line: number
}

// Find lint patterns in content - uses context.content
function findLintPatterns(content: string): LintMatch[] {
  const matches: LintMatch[] = []

  for (const pattern of LINT_PATTERNS) {
    // Match the keyword followed by optional colon and any text until end of line
    // This regex finds the keyword in comments
    const regex = new RegExp(`\\b(${pattern.keyword})\\b`, "gi")
    let match

    while ((match = regex.exec(content)) !== null) {
      // Calculate line number
      const beforeMatch = content.substring(0, match.index)
      const line = beforeMatch.split("\n").length - 1

      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        keyword: pattern.keyword,
        styleName: pattern.styleName,
        line,
      })
    }
  }

  // Sort by position
  matches.sort((a, b) => a.start - b.start)

  return matches
}

// Create the lint highlighter callback - showcases using context
function createLintHighlighter(enabledPatterns: Set<string>): OnHighlightCallback {
  return (highlights: SimpleHighlight[], context: HighlightContext) => {
    // Use context.filetype to conditionally apply highlighting
    // Only highlight lint patterns in supported file types
    if (!SUPPORTED_FILETYPES.has(context.filetype)) {
      // For unsupported file types, return original highlights unchanged
      return highlights
    }

    // Use context.content to find lint patterns
    const lintMatches = findLintPatterns(context.content)

    if (lintMatches.length === 0) {
      return highlights
    }

    // Add lint highlights on top of existing tree-sitter highlights
    // Only add highlights for enabled patterns
    for (const match of lintMatches) {
      if (enabledPatterns.has(match.keyword)) {
        highlights.push([match.start, match.end, match.styleName, {}])
      }
    }

    return highlights
  }
}

// Count lint patterns by type
function countLintPatterns(content: string): Map<string, number> {
  const counts = new Map<string, number>()

  for (const pattern of LINT_PATTERNS) {
    counts.set(pattern.keyword, 0)
  }

  const matches = findLintPatterns(content)
  for (const match of matches) {
    counts.set(match.keyword, (counts.get(match.keyword) || 0) + 1)
  }

  return counts
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

// Track which patterns are enabled
let enabledPatterns = new Set(LINT_PATTERNS.map((p) => p.keyword))
let lintHighlightEnabled = true

function updateHighlighter() {
  if (codeDisplay) {
    if (lintHighlightEnabled && enabledPatterns.size > 0) {
      codeDisplay.onHighlight = createLintHighlighter(enabledPatterns)
    } else {
      codeDisplay.onHighlight = undefined
    }
  }
}

function updateInfoText() {
  if (infoText) {
    const enabledList = Array.from(enabledPatterns).join(", ") || "none"
    infoText.content = `Lint highlighting: ${lintHighlightEnabled ? "ON" : "OFF"} | Enabled: ${enabledList}`
  }
}

function updateStatsText() {
  if (statsText) {
    const counts = countLintPatterns(sampleCode)
    const parts: string[] = []

    for (const pattern of LINT_PATTERNS) {
      const count = counts.get(pattern.keyword) || 0
      if (count > 0) {
        const enabled = enabledPatterns.has(pattern.keyword) ? "" : " (off)"
        parts.push(`${pattern.keyword}: ${count}${enabled}`)
      }
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
    borderColor: "#F59E0B",
    backgroundColor: "#0D1117",
    title: "Lint Pattern Highlighter Demo",
    titleAlignment: "center",
    border: true,
  })
  parentContainer.add(titleBox)

  const instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    content: "ESC return | L toggle all | 1-6 toggle patterns | Uses context.content & context.filetype",
    fg: "#888888",
  })
  titleBox.add(instructionsText)

  // Pattern legend
  const legendBox = new BoxRenderable(renderer, {
    id: "legend-box",
    height: 3,
    border: true,
    borderStyle: "single",
    borderColor: "#475569",
    backgroundColor: "#161B22",
    title: "Patterns (1-6 to toggle)",
    titleAlignment: "left",
    flexShrink: 0,
  })
  parentContainer.add(legendBox)

  const legendText = new TextRenderable(renderer, {
    id: "legend-text",
    content: "1:TODO  2:FIXME  3:HACK  4:NOTE  5:XXX  6:DEPRECATED",
    fg: "#A5D6FF",
  })
  legendBox.add(legendText)

  codeScrollBox = new ScrollBoxRenderable(renderer, {
    id: "code-scroll-box",
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#0D1117",
    title: "TypeScript - Lint Patterns",
    titleAlignment: "left",
    border: true,
    scrollY: true,
    scrollX: false,
    flexGrow: 1,
    flexShrink: 1,
  })
  parentContainer.add(codeScrollBox)

  // Create syntax style with lint highlight styles pre-registered
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

    // Lint highlight styles - registered upfront, NOT in the callback
    "lint.todo": {
      fg: parseColor("#000000"),
      bg: parseColor("#FBBF24"), // Amber/yellow
      bold: true,
    },
    "lint.fixme": {
      fg: parseColor("#FFFFFF"),
      bg: parseColor("#EF4444"), // Red
      bold: true,
    },
    "lint.hack": {
      fg: parseColor("#000000"),
      bg: parseColor("#F97316"), // Orange
      bold: true,
    },
    "lint.note": {
      fg: parseColor("#000000"),
      bg: parseColor("#22C55E"), // Green
      bold: true,
    },
    "lint.xxx": {
      fg: parseColor("#FFFFFF"),
      bg: parseColor("#A855F7"), // Purple
      bold: true,
    },
    "lint.deprecated": {
      fg: parseColor("#FFFFFF"),
      bg: parseColor("#6B7280"), // Gray
      bold: true,
      italic: true,
    },
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
    onHighlight: createLintHighlighter(enabledPatterns),
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
    // L to toggle all lint highlighting
    if (key.name === "l" && !key.ctrl && !key.meta) {
      lintHighlightEnabled = !lintHighlightEnabled
      updateHighlighter()
      updateInfoText()
      return
    }

    // 1-6 to toggle individual patterns
    const patternIndex = parseInt(key.raw || "", 10) - 1
    if (patternIndex >= 0 && patternIndex < LINT_PATTERNS.length) {
      const pattern = LINT_PATTERNS[patternIndex]
      if (enabledPatterns.has(pattern.keyword)) {
        enabledPatterns.delete(pattern.keyword)
      } else {
        enabledPatterns.add(pattern.keyword)
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
  enabledPatterns = new Set(LINT_PATTERNS.map((p) => p.keyword))
  lintHighlightEnabled = true

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

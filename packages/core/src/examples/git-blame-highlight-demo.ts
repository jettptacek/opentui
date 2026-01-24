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

// Sample code that we'll pretend has git blame data
const sampleCode = `import { useState, useEffect } from 'react';
import { api } from './services/api';

interface User {
  id: number;
  name: string;
  email: string;
  createdAt: Date;
}

export function UserProfile({ userId }: { userId: number }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;

    async function fetchUser() {
      try {
        setLoading(true);
        const data = await api.getUser(userId);
        if (mounted) {
          setUser(data);
          setError(null);
        }
      } catch (err) {
        if (mounted) {
          setError('Failed to load user');
          setUser(null);
        }
      } finally {
        if (mounted) {
          setLoading(false);
        }
      }
    }

    fetchUser();

    return () => {
      mounted = false;
    };
  }, [userId]);

  if (loading) {
    return <div className="loading">Loading...</div>;
  }

  if (error) {
    return <div className="error">{error}</div>;
  }

  if (!user) {
    return <div className="not-found">User not found</div>;
  }

  return (
    <div className="user-profile">
      <h1>{user.name}</h1>
      <p className="email">{user.email}</p>
      <p className="joined">
        Joined: {user.createdAt.toLocaleDateString()}
      </p>
    </div>
  );
}

export function UserList() {
  const [users, setUsers] = useState<User[]>([]);

  useEffect(() => {
    api.getUsers().then(setUsers);
  }, []);

  return (
    <ul>
      {users.map(user => (
        <li key={user.id}>
          <UserProfile userId={user.id} />
        </li>
      ))}
    </ul>
  );
}
`

// Simulated git blame data - in a real app this would come from git
// Each entry represents: { lineStart, lineEnd, author, date, commitHash, message }
interface BlameEntry {
  lineStart: number // 0-indexed
  lineEnd: number // exclusive
  author: string
  date: Date
  commitHash: string
  message: string
}

// Helper to create dates relative to now
function daysAgo(days: number): Date {
  const date = new Date()
  date.setDate(date.getDate() - days)
  return date
}

// Simulated blame data with different ages (relative to current date)
const blameData: BlameEntry[] = [
  // Very old - initial commit (2 years ago)
  {
    lineStart: 0,
    lineEnd: 2,
    author: "alice",
    date: daysAgo(730), // ~2 years
    commitHash: "a1b2c3d",
    message: "Initial project setup",
  },
  // Old - 15 months ago
  {
    lineStart: 2,
    lineEnd: 10,
    author: "bob",
    date: daysAgo(450), // ~15 months
    commitHash: "e4f5g6h",
    message: "Add User interface",
  },
  // Medium - 8 months ago
  {
    lineStart: 10,
    lineEnd: 25,
    author: "alice",
    date: daysAgo(240), // ~8 months
    commitHash: "i7j8k9l",
    message: "Create UserProfile component",
  },
  // Recent - 2 months ago
  {
    lineStart: 25,
    lineEnd: 45,
    author: "charlie",
    date: daysAgo(60), // ~2 months
    commitHash: "m1n2o3p",
    message: "Add error handling to UserProfile",
  },
  // Fresh - 2 weeks ago
  {
    lineStart: 45,
    lineEnd: 60,
    author: "bob",
    date: daysAgo(14), // 2 weeks
    commitHash: "q4r5s6t",
    message: "Add loading and error states UI",
  },
  // Brand new - 2 days ago
  {
    lineStart: 60,
    lineEnd: 70,
    author: "alice",
    date: daysAgo(2), // 2 days
    commitHash: "u7v8w9x",
    message: "Add user profile display",
  },
  // Fresh - 10 days ago
  {
    lineStart: 70,
    lineEnd: 85,
    author: "charlie",
    date: daysAgo(10), // 10 days
    commitHash: "y1z2a3b",
    message: "Add UserList component",
  },
]

// Age categories based on how old the commit is
type AgeCategory = "ancient" | "old" | "medium" | "recent" | "fresh" | "new"

const AGE_STYLES: Record<AgeCategory, string> = {
  ancient: "blame.ancient", // > 18 months - very faded
  old: "blame.old", // 12-18 months
  medium: "blame.medium", // 6-12 months
  recent: "blame.recent", // 1-6 months
  fresh: "blame.fresh", // 1 week - 1 month
  new: "blame.new", // < 1 week - brightest
}

// Author colors
const AUTHOR_STYLES: Record<string, string> = {
  alice: "author.alice",
  bob: "author.bob",
  charlie: "author.charlie",
}

function getAgeCategory(date: Date): AgeCategory {
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffDays = diffMs / (1000 * 60 * 60 * 24)

  if (diffDays > 540) return "ancient" // > 18 months
  if (diffDays > 365) return "old" // 12-18 months
  if (diffDays > 180) return "medium" // 6-12 months
  if (diffDays > 30) return "recent" // 1-6 months
  if (diffDays > 7) return "fresh" // 1 week - 1 month
  return "new" // < 1 week
}

// Get line ranges (start/end offsets) from content
function getLineOffsets(content: string): Array<{ start: number; end: number }> {
  const lines: Array<{ start: number; end: number }> = []
  let offset = 0

  const contentLines = content.split("\n")
  for (const line of contentLines) {
    lines.push({ start: offset, end: offset + line.length })
    offset += line.length + 1 // +1 for newline
  }

  return lines
}

// Find blame entry for a given line
function getBlameForLine(lineIndex: number): BlameEntry | undefined {
  return blameData.find((entry) => lineIndex >= entry.lineStart && lineIndex < entry.lineEnd)
}

type HighlightMode = "age" | "author" | "both" | "off"

// Create the git blame highlighter callback
function createBlameHighlighter(mode: HighlightMode): OnHighlightCallback {
  return (highlights: SimpleHighlight[], context: HighlightContext) => {
    if (mode === "off") {
      return highlights
    }

    // Use context.filetype to only highlight code files
    const codeFiletypes = new Set([
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
    ])

    if (!codeFiletypes.has(context.filetype)) {
      return highlights
    }

    // Use context.content to get line offsets
    const lineOffsets = getLineOffsets(context.content)

    // Apply blame highlighting to each line
    for (let lineIndex = 0; lineIndex < lineOffsets.length; lineIndex++) {
      const blame = getBlameForLine(lineIndex)
      if (!blame) continue

      const { start, end } = lineOffsets[lineIndex]
      if (start >= end) continue // Skip empty lines

      if (mode === "age" || mode === "both") {
        const ageCategory = getAgeCategory(blame.date)
        const ageStyle = AGE_STYLES[ageCategory]
        highlights.push([start, end, ageStyle, {}])
      }

      if (mode === "author" || mode === "both") {
        const authorStyle = AUTHOR_STYLES[blame.author] || "author.unknown"
        // For author mode, we add a subtle underline effect by using the style
        highlights.push([start, end, authorStyle, {}])
      }
    }

    return highlights
  }
}

// Get blame statistics
function getBlameStats(): {
  byAuthor: Map<string, number>
  byAge: Map<AgeCategory, number>
  totalLines: number
} {
  const byAuthor = new Map<string, number>()
  const byAge = new Map<AgeCategory, number>()
  let totalLines = 0

  for (const entry of blameData) {
    const lineCount = entry.lineEnd - entry.lineStart
    totalLines += lineCount

    // Count by author
    byAuthor.set(entry.author, (byAuthor.get(entry.author) || 0) + lineCount)

    // Count by age
    const age = getAgeCategory(entry.date)
    byAge.set(age, (byAge.get(age) || 0) + lineCount)
  }

  return { byAuthor, byAge, totalLines }
}

let renderer: CliRenderer | null = null
let keyboardHandler: ((key: ParsedKey) => void) | null = null
let parentContainer: BoxRenderable | null = null
let codeScrollBox: ScrollBoxRenderable | null = null
let codeDisplay: CodeRenderable | null = null
let codeWithLineNumbers: LineNumberRenderable | null = null
let infoText: TextRenderable | null = null
let statsText: TextRenderable | null = null
let blameInfoText: TextRenderable | null = null
let syntaxStyle: SyntaxStyle | null = null

let highlightMode: HighlightMode = "age"

function updateHighlighter() {
  if (codeDisplay) {
    codeDisplay.onHighlight = createBlameHighlighter(highlightMode)
  }
}

function updateInfoText() {
  if (infoText) {
    const modeDesc = {
      age: "Age (older = more faded)",
      author: "Author colors",
      both: "Age + Author",
      off: "Off",
    }
    infoText.content = `Mode: ${modeDesc[highlightMode]} | M: cycle mode | Uses context.content + context.filetype`
  }
}

function updateStatsText() {
  if (statsText) {
    const stats = getBlameStats()
    const authorParts = Array.from(stats.byAuthor.entries())
      .map(([author, lines]) => `${author}: ${lines}`)
      .join(", ")
    statsText.content = `Lines by author: ${authorParts}`
  }
}

function updateBlameInfo(lineIndex: number) {
  if (blameInfoText) {
    const blame = getBlameForLine(lineIndex)
    if (blame) {
      const age = getAgeCategory(blame.date)
      const dateStr = blame.date.toLocaleDateString()
      blameInfoText.content = `Line ${lineIndex + 1}: ${blame.commitHash} | ${blame.author} | ${dateStr} (${age}) | "${blame.message}"`
    } else {
      blameInfoText.content = `Line ${lineIndex + 1}: No blame data`
    }
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
    borderColor: "#3B82F6",
    backgroundColor: "#0D1117",
    title: "Git Blame Line Age Highlighter Demo",
    titleAlignment: "center",
    border: true,
  })
  parentContainer.add(titleBox)

  const instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    content: "ESC return | M: cycle mode (age/author/both/off) | Scroll to see different ages",
    fg: "#888888",
  })
  titleBox.add(instructionsText)

  // Legend box
  const legendBox = new BoxRenderable(renderer, {
    id: "legend-box",
    height: 4,
    border: true,
    borderStyle: "single",
    borderColor: "#475569",
    backgroundColor: "#161B22",
    title: "Age Legend (brightness = recency)",
    titleAlignment: "left",
    flexShrink: 0,
  })
  parentContainer.add(legendBox)

  const legendText = new TextRenderable(renderer, {
    id: "legend-text",
    content:
      "ancient:red(>18mo) old:brown(12-18mo) medium:olive(6-12mo) recent:teal(1-6mo) fresh:blue(1wk-1mo) new:green(<1wk)\nAuthors: alice(deep blue) bob(green) charlie(magenta)",
    fg: "#A5D6FF",
    wrapMode: "word",
  })
  legendBox.add(legendText)

  codeScrollBox = new ScrollBoxRenderable(renderer, {
    id: "code-scroll-box",
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#0D1117",
    title: "TypeScript - Simulated Git Blame",
    titleAlignment: "left",
    border: true,
    scrollY: true,
    scrollX: false,
    flexGrow: 1,
    flexShrink: 1,
  })
  parentContainer.add(codeScrollBox)

  // Create syntax style with blame highlight styles pre-registered
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

    // Age-based background colors - each age has a distinct hue
    "blame.ancient": { bg: parseColor("#3d1a1a") }, // Dark red - oldest/coldest
    "blame.old": { bg: parseColor("#3d2b1a") }, // Brown/rust
    "blame.medium": { bg: parseColor("#3d3d1a") }, // Olive/yellow-brown
    "blame.recent": { bg: parseColor("#1a3d2b") }, // Teal/dark green
    "blame.fresh": { bg: parseColor("#1a2b3d") }, // Steel blue
    "blame.new": { bg: parseColor("#1a3d1a") }, // Bright green - newest/freshest

    // Author colors (distinct background tints)
    "author.alice": { bg: parseColor("#1a1a4d") }, // Deep blue tint
    "author.bob": { bg: parseColor("#1a4d1a") }, // Green tint
    "author.charlie": { bg: parseColor("#4d1a4d") }, // Magenta tint
    "author.unknown": { bg: parseColor("#2a2a2a") }, // Gray
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
    onHighlight: createBlameHighlighter(highlightMode),
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

  // Blame info display (shows blame for current line)
  blameInfoText = new TextRenderable(renderer, {
    id: "blame-info-display",
    content: "Scroll to see blame info for each line",
    fg: "#FFA657",
    wrapMode: "word",
    flexShrink: 0,
  })
  parentContainer.add(blameInfoText)

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
  updateBlameInfo(0)

  // Update blame info when scrolling
  codeScrollBox.on("scroll", () => {
    const topLine = Math.floor(codeScrollBox?.scrollTop || 0)
    updateBlameInfo(topLine)
  })

  keyboardHandler = (key: ParsedKey) => {
    // M to cycle highlight mode
    if (key.name === "m" && !key.ctrl && !key.meta) {
      const modes: HighlightMode[] = ["age", "author", "both", "off"]
      const currentIndex = modes.indexOf(highlightMode)
      highlightMode = modes[(currentIndex + 1) % modes.length]
      updateHighlighter()
      updateInfoText()
      return
    }

    // Number keys to jump to different sections
    if (key.raw === "1") {
      if (codeScrollBox) codeScrollBox.scrollTop = 0
      updateBlameInfo(0)
    } else if (key.raw === "2") {
      if (codeScrollBox) codeScrollBox.scrollTop = 10
      updateBlameInfo(10)
    } else if (key.raw === "3") {
      if (codeScrollBox) codeScrollBox.scrollTop = 25
      updateBlameInfo(25)
    } else if (key.raw === "4") {
      if (codeScrollBox) codeScrollBox.scrollTop = 45
      updateBlameInfo(45)
    } else if (key.raw === "5") {
      if (codeScrollBox) codeScrollBox.scrollTop = 60
      updateBlameInfo(60)
    } else if (key.raw === "6") {
      if (codeScrollBox) codeScrollBox.scrollTop = 70
      updateBlameInfo(70)
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
  blameInfoText = null
  syntaxStyle = null

  // Reset state
  highlightMode = "age"

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

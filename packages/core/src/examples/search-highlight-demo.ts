import {
  CliRenderer,
  createCliRenderer,
  CodeRenderable,
  BoxRenderable,
  TextRenderable,
  TextareaRenderable,
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

// Sample code to search through
const sampleCode = `import { useState, useEffect, useCallback } from 'react';
import { fetchUsers, updateUser, deleteUser } from './api';

interface User {
  id: number;
  name: string;
  email: string;
  role: 'admin' | 'user' | 'guest';
}

interface UserListProps {
  initialUsers?: User[];
  onUserSelect?: (user: User) => void;
}

export function UserList({ initialUsers = [], onUserSelect }: UserListProps) {
  const [users, setUsers] = useState<User[]>(initialUsers);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedUser, setSelectedUser] = useState<User | null>(null);

  useEffect(() => {
    const loadUsers = async () => {
      setLoading(true);
      try {
        const data = await fetchUsers();
        setUsers(data);
      } catch (err) {
        setError('Failed to load users');
      } finally {
        setLoading(false);
      }
    };

    if (initialUsers.length === 0) {
      loadUsers();
    }
  }, [initialUsers]);

  const handleUserClick = useCallback((user: User) => {
    setSelectedUser(user);
    onUserSelect?.(user);
  }, [onUserSelect]);

  const handleDeleteUser = async (userId: number) => {
    try {
      await deleteUser(userId);
      setUsers(users.filter(u => u.id !== userId));
    } catch (err) {
      setError('Failed to delete user');
    }
  };

  const handleUpdateUser = async (user: User) => {
    try {
      const updated = await updateUser(user);
      setUsers(users.map(u => u.id === updated.id ? updated : u));
    } catch (err) {
      setError('Failed to update user');
    }
  };

  if (loading) {
    return <div className="loading">Loading users...</div>;
  }

  if (error) {
    return <div className="error">{error}</div>;
  }

  return (
    <div className="user-list">
      <h2>Users ({users.length})</h2>
      {users.map(user => (
        <div
          key={user.id}
          className={\`user-item \${selectedUser?.id === user.id ? 'selected' : ''}\`}
          onClick={() => handleUserClick(user)}
        >
          <span className="user-name">{user.name}</span>
          <span className="user-email">{user.email}</span>
          <span className={\`user-role role-\${user.role}\`}>{user.role}</span>
          <button onClick={() => handleDeleteUser(user.id)}>Delete</button>
          <button onClick={() => handleUpdateUser(user)}>Edit</button>
        </div>
      ))}
    </div>
  );
}

// Helper function to filter users by role
export function filterUsersByRole(users: User[], role: User['role']): User[] {
  return users.filter(user => user.role === role);
}

// Helper function to search users by name or email
export function searchUsers(users: User[], query: string): User[] {
  const lowerQuery = query.toLowerCase();
  return users.filter(user =>
    user.name.toLowerCase().includes(lowerQuery) ||
    user.email.toLowerCase().includes(lowerQuery)
  );
}`

interface SearchMatch {
  start: number
  end: number
  line: number
  column: number
}

function findSearchMatches(text: string, searchTerm: string): SearchMatch[] {
  if (!searchTerm) return []

  const matches: SearchMatch[] = []
  const lowerText = text.toLowerCase()
  const lowerSearch = searchTerm.toLowerCase()
  let pos = 0

  while ((pos = lowerText.indexOf(lowerSearch, pos)) !== -1) {
    // Calculate line and column
    const beforeMatch = text.substring(0, pos)
    const lines = beforeMatch.split("\n")
    const line = lines.length - 1
    const column = lines[lines.length - 1].length

    matches.push({
      start: pos,
      end: pos + searchTerm.length,
      line,
      column,
    })
    pos += 1 // Move forward to find overlapping matches
  }

  return matches
}

function createSearchHighlighter(matches: SearchMatch[], currentMatchIndex: number): OnHighlightCallback {
  return (highlights) => {
    for (let i = 0; i < matches.length; i++) {
      const match = matches[i]
      const styleName = i === currentMatchIndex ? "search.current" : "search.match"
      highlights.push([match.start, match.end, styleName, {}])
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
let searchInput: TextareaRenderable | null = null
let infoText: TextRenderable | null = null
let syntaxStyle: SyntaxStyle | null = null

let searchTerm = ""
let matches: SearchMatch[] = []
let currentMatchIndex = 0

function updateSearch(newSearchTerm: string) {
  searchTerm = newSearchTerm
  matches = findSearchMatches(sampleCode, searchTerm)
  currentMatchIndex = matches.length > 0 ? 0 : -1

  if (codeDisplay) {
    codeDisplay.onHighlight = searchTerm ? createSearchHighlighter(matches, currentMatchIndex) : undefined
  }

  updateInfoText()
  scrollToCurrentMatch()
}

function jumpToMatch(index: number) {
  if (matches.length === 0) return

  currentMatchIndex = ((index % matches.length) + matches.length) % matches.length

  if (codeDisplay) {
    codeDisplay.onHighlight = createSearchHighlighter(matches, currentMatchIndex)
  }

  updateInfoText()
  scrollToCurrentMatch()
}

function nextMatch() {
  jumpToMatch(currentMatchIndex + 1)
}

function prevMatch() {
  jumpToMatch(currentMatchIndex - 1)
}

function scrollToCurrentMatch() {
  if (matches.length === 0 || currentMatchIndex < 0) return

  const match = matches[currentMatchIndex]
  if (codeScrollBox) {
    // Scroll to put the match line in view (with some padding)
    const targetLine = Math.max(0, match.line - 3)
    codeScrollBox.scrollTop = targetLine
  }
}

function updateInfoText() {
  if (infoText) {
    if (searchTerm && matches.length > 0) {
      infoText.content = `Found ${matches.length} match${matches.length === 1 ? "" : "es"} | Current: ${currentMatchIndex + 1}/${matches.length} (line ${matches[currentMatchIndex].line + 1}) | n/N: next/prev | /: search | ESC: clear`
    } else if (searchTerm && matches.length === 0) {
      infoText.content = `No matches found for "${searchTerm}" | /: search | ESC: clear`
    } else {
      infoText.content = "/ or Enter: search | n/N: next/prev match | Ctrl+F: focus search | ESC: return"
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
    borderColor: "#4ECDC4",
    backgroundColor: "#0D1117",
    title: "Search & Highlight Demo",
    titleAlignment: "center",
    border: true,
  })
  parentContainer.add(titleBox)

  const instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    content: "ESC to return | Type to search, n/N to navigate matches",
    fg: "#888888",
  })
  titleBox.add(instructionsText)

  // Search input box
  const searchBox = new BoxRenderable(renderer, {
    id: "search-box",
    height: 3,
    border: true,
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#161B22",
    title: "Search",
    titleAlignment: "left",
    flexShrink: 0,
  })
  parentContainer.add(searchBox)

  searchInput = new TextareaRenderable(renderer, {
    id: "search-input",
    width: "100%",
    height: 1,
    placeholder: "Type to search...",
    backgroundColor: "transparent",
    focusedBackgroundColor: "transparent",
    textColor: "#E2E8F0",
    focusedTextColor: "#F8FAFC",
    wrapMode: "none",
    showCursor: true,
    cursorColor: "#60A5FA",
    onContentChange: () => {
      if (searchInput) {
        updateSearch(searchInput.editBuffer.getText())
      }
    },
  })
  searchBox.add(searchInput)
  // Don't auto-focus - let user press / or Enter to start searching

  codeScrollBox = new ScrollBoxRenderable(renderer, {
    id: "code-scroll-box",
    borderStyle: "single",
    borderColor: "#6BCF7F",
    backgroundColor: "#0D1117",
    title: "TypeScript - User Management",
    titleAlignment: "left",
    border: true,
    scrollY: true,
    scrollX: false,
    flexGrow: 1,
    flexShrink: 1,
  })
  parentContainer.add(codeScrollBox)

  // Create syntax style
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

    // search highlight styles (registered once)
    "search.match": {
      fg: RGBA.fromInts(0, 0, 0),
      bg: RGBA.fromInts(255, 255, 0),
    },
    "search.current": {
      fg: RGBA.fromInts(0, 0, 0),
      bg: RGBA.fromInts(255, 165, 0),
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
    content: "/ or Enter: search | n/N: next/prev match | Ctrl+F: focus search | ESC: return",
    fg: "#A5D6FF",
    wrapMode: "word",
    flexShrink: 0,
  })
  parentContainer.add(infoText)

  keyboardHandler = (key: ParsedKey) => {
    // Ctrl+F to focus search (works from anywhere)
    if (key.name === "f" && key.ctrl) {
      searchInput?.focus()
      return
    }

    // Handle escape - blur input, or clear search, or let it bubble to return to menu
    if (key.name === "escape") {
      if (searchInput?.focused) {
        searchInput.blur()
        return
      } else if (searchTerm) {
        // Clear search
        if (searchInput) {
          searchInput.editBuffer.setText("")
        }
        updateSearch("")
        return
      }
      // Let ESC bubble up to return to menu
      return
    }

    // When search input is focused, Enter blurs it to allow navigation
    if (searchInput?.focused) {
      if (key.name === "return" || key.name === "linefeed") {
        searchInput.blur()
        return
      }
      // Let other keys go to the input
      return
    }

    // When NOT focused on input:
    // Enter focuses the search input
    if (key.name === "return" || key.name === "linefeed") {
      // Focus after current event is fully processed so Enter isn't captured by textarea
      queueMicrotask(() => searchInput?.focus())
      return
    }

    // n/N for navigation
    if (key.name === "n" && !key.shift && !key.ctrl && !key.meta) {
      nextMatch()
      return
    }
    if ((key.name === "n" && key.shift) || key.name === "N") {
      prevMatch()
      return
    }

    // F3 / Shift+F3 for navigation
    if (key.name === "f3") {
      if (key.shift) {
        prevMatch()
      } else {
        nextMatch()
      }
      return
    }

    // / to focus search (vim-style)
    if (key.raw === "/") {
      // Focus after current event is fully processed so / isn't captured by textarea
      queueMicrotask(() => searchInput?.focus())
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
  searchInput = null
  infoText = null
  syntaxStyle = null

  // Reset state
  searchTerm = ""
  matches = []
  currentMatchIndex = 0

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

# Devgentic Design Guidelines

> The definitive reference for Devgentic's macOS interface.
> Every new view, component, and interaction should align with this document.
> Last updated: March 2026

---

## 1. Core Design Philosophy

### Identity

Devgentic is a **professional-grade, developer-first AI companion** for macOS. The interface must feel like a tool built by developers, for developers — not a consumer chatbot wearing a dark theme.

### Mood

**Quiet confidence.** The UI stays out of the way until needed. Surfaces are calm, interactions are precise, and AI features announce themselves with restraint — never with flashy animations or gratuitous decoration.

Think: Linear, Raycast, Warp terminal — tools that respect the user's focus.

### Target Audience

Senior developers and power users on Apple Silicon Macs who:
- Run local LLMs alongside their IDE
- Expect keyboard-first workflows
- Value information density over whitespace
- Notice when animations are 50ms too slow

### Primary UX Goals

| Priority | Goal | How We Achieve It |
|----------|------|-------------------|
| 1 | **Zero friction** | Single-window architecture, keyboard shortcuts on every action, no modal interruptions for routine tasks |
| 2 | **Transparency** | Glass-box agent execution (timeline events), model fit badges, IC lifecycle logs — never hide what the system is doing |
| 3 | **Trust** | All inference runs locally, clear "AI Generated" badges, user controls every toggle, no silent background tasks |
| 4 | **Density without clutter** | Compact rows, nested cards for hierarchy, collapsible sections — show more data in less space without feeling cramped |

### What We Are NOT

- Not a "fun" app with emoji, confetti, or gamification
- Not a skeuomorphic design with fake textures
- Not a web app ported to macOS — we use native controls where appropriate
- Not afraid of text — we prefer precise labels over ambiguous icons

---

## 2. Layout Strategy

### Single-Window Architecture

The entire app runs in a single `WindowGroup`. No separate settings windows, no floating panels, no multi-window sprawl.

```
┌─────────────────────────────────────────────────────┐
│ ┌──────┬────────────┬──────────────────────────────┐ │
│ │      │            │                              │ │
│ │  A   │     S      │          Content             │ │
│ │  c   │     i      │                              │ │
│ │  t   │     d      │   Chat / Settings / Store    │ │
│ │  i   │     e      │                              │ │
│ │  v   │     b      │                              │ │
│ │  i   │     a      ├──────────────────────────────┤ │
│ │  t   │     r      │       Input Area             │ │
│ │  y   │            │                              │ │
│ └──────┴────────────┴──────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Activity Bar**: Fixed 50px vertical strip on the far left. Icon-only navigation to top-level sections.

**Sidebar Pane**: 320px default width (resizable). Context-sensitive content based on Activity Bar selection — conversations, file explorer, prompts, backend profiles, scheduled tasks.

**Content Area**: Fills remaining space. Either chat (always alive via opacity toggling) or a pushed destination (settings, model store, profile detail).

### Sidebar Behavior

- Toggle visibility with `⌘B`
- Spring animation: `response: 0.35, dampingFraction: 0.8`
- 12px gap between sidebar edge and content area
- Shadow on sidebar: `opacity: 0.18, radius: 15, y: 6`
- 1px border with `surfaceOverlayStrong.opacity(0.5)`
- Corner radius: 16px on the sidebar container

### Navigation: Push/Pop Stack

All non-chat destinations use `MainViewRouter` — a stack-based navigator that pushes views on top of the chat layer:

```
Chat → Settings → Core Intelligence → Model Store
                                      ↑ Back button returns here
```

**Key Rules:**
- Chat is **never destroyed** — it's kept alive via opacity toggling (`opacity: 0` when hidden, `opacity: 1` when active)
- Non-chat views are **lazily created** on push and destroyed on pop
- `returnToChat()` clears the entire stack and restores chat
- Deep-link navigation (e.g., sidebar → settings category) resets the stack first

### Content Area Layout

When chat is active and no conversation is selected, the **WelcomeView** is shown as an overlay on the chat history.

Chat input area is pinned to the bottom with:
- 15px bottom padding
- 4px top padding
- Horizontal padding matching the content width
- Drop shadow: `opacity: 0.2, radius: 10, y: 5`

---

## 3. Component Styling

### 3.1 Cards

Cards are the primary grouping container. Two hierarchies exist:

#### SettingsCard (Top-Level Container)

Used in settings panels to group related controls.

```
┌─ icon  Title ──────────────────────────────┐
│ ┌────────────────────────────────────────┐ │
│ │  SettingsRow 1                         │ │
│ ├────────────────────────────────────────┤ │
│ │  SettingsRow 2                         │ │
│ └────────────────────────────────────────┘ │
└────────────────────────────────────────────┘
```

| Property | Value |
|----------|-------|
| Background | `theme.controlBackground` |
| Corner radius | 12px |
| Border | 1px, `theme.surfaceOverlayStrong` |
| Header icon | `theme.accentColor`, 16px |
| Header title | 15px, semibold |
| Header spacing | 8px between icon and title |
| Content clip | `RoundedRectangle(cornerRadius: 12, style: .continuous)` |

#### Nested Card (Inside Containers)

Used for individual items within a larger container (e.g., insight cards inside Morning Brief).

| Property | Value |
|----------|-------|
| Background | `theme.secondaryBackground.opacity(0.5)` |
| Corner radius | 10px |
| Border | 0.5px, `theme.surfaceOverlayStrong.opacity(0.6)` |
| Padding | 12px |

### 3.2 Settings Rows

The atomic unit of settings UI. Always placed inside a `SettingsCard`.

| Property | Value |
|----------|-------|
| Padding | 16px all sides |
| Title font | 14px, medium |
| Description font | 12px, regular, `theme.secondaryText` |
| Description line spacing | 2pt |
| Control alignment | Right-aligned, vertically centered |
| Min gap (label ↔ control) | 24px |
| Divider between rows | `Divider().background(theme.dividerColor)` |

### 3.3 Feature Toggle Rows

Extended settings row with icon, title, description, and toggle.

| Property | Value |
|----------|-------|
| Icon frame | 24px width |
| Icon font | 16px |
| Icon color (active) | `theme.accentColor` |
| Icon color (inactive) | `theme.secondaryText` |
| Icon top padding | 2px |
| Toggle tint | `theme.accentColor` |
| "Coming Soon" badge | 9px bold, white on `theme.secondaryText.opacity(0.6)`, 4px radius |
| Disabled opacity | 0.6 |
| Padding | 16px |

### 3.4 Quick Action Cards

Interactive cards with icon, title, subtitle, and optional keyboard shortcut.

| Property | Value |
|----------|-------|
| Layout | 2-column `LazyVGrid`, 12px spacing |
| Icon container | 38×38px circle with gradient fill |
| Icon size | 16px, medium weight |
| Card padding | 14px |
| Card corner radius | 12px |
| Title | 13px, semibold |
| Subtitle | 11px, regular, `theme.tertiaryText` |
| Shortcut badge | 10px monospaced, 5px h-padding, 1px v-padding, 4px radius, `theme.secondaryBackground` |
| Hover border | Accent color at 0.4 opacity |
| Hover shadow | Radius increases from 6 → 12, opacity from 0.03 → 0.08 |
| Hover scale | 1.0 → 1.01 |
| Hover animation | `easeOut(duration: 0.2)` |

### 3.5 Badges & Pills

#### Model Fit Badge (Verdict Indicator)

| Verdict | Color | Icon |
|---------|-------|------|
| Comfortable | Green | `checkmark.circle.fill` |
| Tight | Yellow | `exclamationmark.triangle.fill` |
| Risky | Orange | `exclamationmark.triangle.fill` |
| Incompatible | Red | `xmark.octagon.fill` |

Badge styling: 6px h-padding, 3px v-padding, 4px radius, background at 0.1 opacity, border at 0.3 opacity, caption2 font.

#### AI Generated Badge (Capsule)

9px semibold text + 9px sparkles icon, `theme.accentColor`, background at 0.1 opacity, capsule shape, 7px h-padding, 3px v-padding.

#### Coming Soon Badge

9px bold, white text, `theme.secondaryText.opacity(0.6)` background, 4px radius, 6px h-padding, 2px v-padding.

### 3.6 Banners

Used for agent interruptions (tool approval, clarification requests).

| Property | Value |
|----------|-------|
| Max width | 1000px |
| Corner radius | 16px |
| Background | `.ultraThinMaterial` |
| Shadow | `black.opacity(0.1)`, radius 6, y: 3 |
| Border | 1px, stream color at 0.15 opacity |
| Padding | 14px horizontal, 12px vertical |
| Indicator dot | 6×6px circle with shadow radius 3 |
| Label | 11px, semibold, uppercase, letter-spacing 0.6 |
| Entry animation | `.move(edge: .bottom).combined(with: .opacity)` |
| Spring | `response: 0.38, dampingFraction: 0.82` |

### 3.7 Buttons

#### Primary (Bordered Prominent)

Used for the main action in a context. Tinted with `theme.accentColor`. `.controlSize(.small)` in settings.

#### Secondary (Bordered)

Used for secondary actions. No custom tint — inherits from system.

#### Ghost (Plain)

Used for tertiary actions and inline links. Font-colored only, no background. Often caption-sized.

#### Dismiss Button (Circle)

Used in dismissible cards (Morning Brief, overlays).

| Property | Value |
|----------|-------|
| Icon | `xmark`, 10px bold |
| Frame | 22×22px |
| Background | `theme.secondaryBackground` |
| Shape | Circle |
| Style | `.plain` |

### 3.8 Text Inputs

#### Standard Input Field

Padding: 10px, corner radius: 8px, border: 1px `theme.dividerColor`.

#### TextEditor (Multi-line)

Padding: 8px, corner radius: 8px, background: `theme.secondaryBackground`, border: 1px `theme.dividerColor`, `.scrollContentBackground(.hidden)`.

#### Focused State

Border color transitions to `theme.streamingIndicator.opacity(0.45)`.

### 3.9 Conversation Sidebar Rows

| Property | Value |
|----------|-------|
| Group header chevron | 9px, semibold, rotates 0→90° |
| Group title | 12px, semibold, opacity 0.9 |
| Count badge | 10px medium, 5px h-padding, 1px v-padding, opacity 0.04 bg |
| Row padding | 8px horizontal, 6px vertical |
| Hover background | `Color.white.opacity(0.04)`, 6px radius |
| Hover animation | `easeInOut(duration: 0.1)` |

---

## 4. Visual Language

### 4.1 Color System

#### Three-Tier Token Architecture

| Tier | Purpose | Override Frequency |
|------|---------|-------------------|
| **Tier 1** | Core backgrounds, text, accent, semantic | Every theme defines these |
| **Tier 2** | Extended surfaces, code blocks, overlays | Most themes override a subset |
| **Tier 3** | Typography, spacing, corner radius | Shared across all themes (protocol defaults) |

#### Theme Palette Signatures

| Theme | Background | Text | Accent | Character |
|-------|-----------|------|--------|-----------|
| **Default** | System adaptive | System adaptive | System | Neutral, follows OS |
| **Dracula** | `#282a36` | `#f8f8f2` | `#bd93f9` (purple) | Rich, saturated, classic dark |
| **One Light** | `#fafafa` | `#383a42` | `#4078f2` (blue) | Clean, paper-like, readable |
| **One Dark** | `#282c34` | `#abb2bf` | `#61afef` (blue) | Muted, Atom-inspired |
| **Cosmic Dark** | `#121212` | White | `#1DB954` (green) | Deep black, Spotify-esque |

#### Surface Overlay System

Overlays create depth without introducing new colors:

| Token | Default Value | Usage |
|-------|--------------|-------|
| `surfaceOverlay` | `Color.white.opacity(0.06)` | Hover tints, subtle highlights |
| `surfaceOverlayStrong` | `Color.white.opacity(0.1)` | Borders, active states, dividers |

In light themes, these flip to `Color.black.opacity(0.04)` and `Color.black.opacity(0.08)`.

#### Accent Color Overrides

Users can override the accent color independently of their theme via `AppAccentColor`:

| Option | Color | Hex |
|--------|-------|-----|
| Default | System | — |
| Ocean Blue | `.systemBlue` | — |
| Forest Green | `.systemGreen` | — |
| Deep Purple | `.systemPurple` | — |
| Sunset Orange | `.systemOrange` | — |
| Vibrant Pink | `.systemPink` | — |
| Cosmic Green | Custom | `#1DB954` |

Applied via `ThemeDecorator` — wraps the base theme and injects the new accent without mutation.

### 4.2 Typography

All fonts use `.system()` — no custom typefaces. This ensures native rendering, accessibility scaling, and zero asset management.

#### Scale

| Role | Size | Weight | Design | Usage |
|------|------|--------|--------|-------|
| Large Title | 32px | Bold | Default | WelcomeView greeting |
| Title 1 | 26px | Semibold | Default | — |
| Title 2 | 20px | Semibold | Default | Modal headings |
| Title 3 | 18px | Semibold | Default | Section headers |
| Headline | 16px | Semibold | Default | Card titles, prominent labels |
| Body | 15px | Regular | Default | Chat messages, descriptions |
| Callout | 14px | Regular | Default | Settings row titles |
| Subheadline | 14px | Regular | Default | Secondary labels |
| Footnote | 13px | Regular | Default | Inline details |
| Caption | 12px | Regular | Default | Descriptions, metadata |
| Caption 2 | 11px | Regular | Default | Timestamps, hints |
| Code | 13px | Regular | **Monospaced** | Code blocks, tool names |
| Code Caption | 10px | Medium | **Monospaced** | Line numbers, shortcut badges |

#### Design Variants

- `.rounded` — Used sparingly for greeting text and card titles that should feel warm (e.g., "Good morning", "Morning Brief")
- `.monospaced` — Used for anything technical: code, tool names, keyboard shortcuts, file paths

#### Key Rule

**Never use hardcoded font sizes outside this scale.** If a new size is needed, add it to the Theme protocol first.

### 4.3 Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `spacingXXSmall` | 2px | Icon-to-label micro-gaps |
| `spacingXSmall` | 4px | Inline element spacing |
| `spacingSmall` | 8px | Row padding, compact gaps |
| `spacingMedium` | 10px | Standard content spacing |
| `spacingLarge` | 14px | Card internal padding |
| `spacingXLarge` | 20px | Section gaps |
| `spacingXXLarge` | 28px | Major section separators |

#### Practical Spacing Patterns

| Context | Value |
|---------|-------|
| Settings row padding (all sides) | 16px |
| Settings card content spacing | 12px |
| Quick action grid gap | 12px |
| Morning Brief insight card padding | 12px |
| Section gap (VStack spacing in settings) | 32px |
| Page padding (ScrollView content) | 24px |
| Bottom page padding | 24px |

### 4.4 Corner Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `cornerRadiusSmall` | 4px | Badges, shortcut keys, small pills |
| `cornerRadiusMedium` | 8px | Input fields, search bars, code blocks |
| `cornerRadiusLarge` | 16px | Cards, sidebar, banners, major containers |

**Additional values in use:**
- 6px — Hover backgrounds, tool chips, capsule-like small elements
- 10px — Nested cards (insight cards inside Morning Brief)
- 12px — Quick action cards, intermediate containers

**Rule:** Always use `.continuous` style for cards and containers: `RoundedRectangle(cornerRadius: N, style: .continuous)`. This produces the iOS/macOS "squircle" that looks native.

### 4.5 Shadows & Depth

Three depth levels are used consistently:

| Level | Radius | Y-Offset | Opacity | Usage |
|-------|--------|----------|---------|-------|
| **Subtle** | 6px | 3-4px | 0.03–0.05 | Cards at rest, keyboard keys |
| **Medium** | 12-15px | 6-8px | 0.05–0.08 | Hovered cards, sidebar |
| **Elevated** | 20-24px | 10-12px | 0.06–0.10 | Morning Brief card, modals |

**Color:** Always `theme.primaryText.opacity(N)` — this ensures shadows adapt to light/dark themes automatically. Never use `Color.black`.

**Exception:** Sidebar uses `Color.black.opacity(0.18)` for stronger grounding.

### 4.6 Borders & Strokes

| Context | Width | Color |
|---------|-------|-------|
| Card borders | 1px | `theme.surfaceOverlayStrong` |
| Nested card borders | 0.5px | `theme.surfaceOverlayStrong.opacity(0.6)` |
| Input field borders | 1px | `theme.dividerColor` |
| Keyboard key borders | 0.5px | `theme.surfaceOverlayStrong` |
| Badge borders | 1px | Badge color at 0.3 opacity |
| Hover state borders | 1px | Accent color at 0.4 opacity |

### 4.7 Gradients

Used sparingly for branding and emphasis:

| Element | Colors | Direction |
|---------|--------|-----------|
| Greeting icon | Time-aware (orange/yellow, yellow/orange, orange/pink, indigo/purple) | bottomLeading → topTrailing |
| Quick action icons | Per-action accent pair | topLeading → bottomTrailing |
| Morning Brief sunrise | Orange → Yellow | bottomLeading → topTrailing |
| App icon in old hero | `theme.accentColor` → `theme.accentMuted` | topLeading → bottomTrailing |
| Chat background | `chatGPTGradientTop` → `chatGPTGradientBottom` | top → bottom |

**Rule:** Gradients are reserved for icons and backgrounds. Never apply gradients to text (except the greeting icon) or interactive controls.

---

## 5. Animation & Motion

### 5.1 Timing Curves

| Type | Parameters | When to Use |
|------|-----------|-------------|
| **Quick spring** | `response: 0.3, dampingFraction: 0.8` | Tab switches, hover states, sidebar toggle |
| **Medium spring** | `response: 0.38, dampingFraction: 0.82` | Banner entrance, permission cards |
| **Deliberate spring** | `response: 0.45, dampingFraction: 0.8` | Insight card entrance, content reveals |
| **Fast ease** | `easeInOut(duration: 0.1–0.2)` | Hover backgrounds, micro-interactions |
| **Standard ease** | `easeInOut(duration: 0.2–0.3)` | Content transitions, brief state changes |
| **Subtle movement** | `easeOut(duration: 0.2–0.4)` | Card entrance, offset animations |
| **Content exit** | `easeIn(duration: 0.5)` | Fading out content |

### 5.2 Entrance Patterns

#### Staggered Entrance (Lists)

Items fade in + slide up with increasing delays:

```swift
// Per-item delay
let delay = Double(index) * 0.12  // 0.12s between items

// Applied properties
.opacity(appeared ? 1 : 0)
.offset(y: appeared ? 0 : 10)
.animation(.spring(response: 0.45, dampingFraction: 0.8).delay(delay))
```

#### Section Stagger (Page-Level)

Major sections of a page animate in with larger gaps:

```swift
// Greeting: immediate
// Brief: +0.0s (follows greeting)
// Quick Actions: +0.1s
// Keyboard Hints: +0.2s
```

### 5.3 Transitions

| Pattern | Usage |
|---------|-------|
| `.opacity` | Simple show/hide (shortcuts card, loading state) |
| `.opacity + .scale(0.96)` | Card insertion (Morning Brief) |
| `.move(edge: .bottom) + .opacity` | Banner entrance |
| `.asymmetric(insertion:removal:)` | Different in/out animations (brief card appears with scale, disappears with fade) |

### 5.4 Hover States

All interactive cards must respond to hover:

```swift
.onHover { hovering in
    withAnimation(.easeOut(duration: 0.2)) {
        isHovering = hovering
    }
}
```

Hover effects to apply (one or more):
- Border color change (accent at 0.4 opacity)
- Shadow intensification (radius + opacity increase)
- Subtle scale (`1.0 → 1.01`)
- Background tint (gradient opacity increase)

### 5.5 Pulse Animation

Used only for loading/generating states:

```swift
Circle()
    .fill(Color.orange.opacity(pulseOpacity))
    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true))
    .onAppear { pulseOpacity = 0.15 }
```

---

## 6. Intelligence Core UI Patterns

### 6.1 Feature Identification

Every IC feature is tracked via `ICCallerFeature` enum for logging. When displaying IC-generated content in the UI:

- **Always** show an "AI Generated" or "AI" badge near the content
- **Always** make the generation dismissible (× button)
- **Never** auto-dismiss AI content — let the user control when it goes away

### 6.2 Loading States

When IC is processing, show:
- A pulse animation (sunrise orb) — not a generic spinner alone
- Descriptive text explaining what's happening ("Analysing recent conversations...")
- A small progress indicator (spinner) as secondary feedback

### 6.3 Suggestion Display

AI suggestions use the orange pill pattern:

```
┌─────────────────────────────────────────┐
│ 💡 Consider writing tests for the       │
│    parser before refactoring.           │
└─────────────────────────────────────────┘
```

| Property | Value |
|----------|-------|
| Background | `Color.orange.opacity(0.06)` |
| Border | 0.5px, `Color.orange.opacity(0.12)` |
| Corner radius | 8px |
| Icon | `lightbulb.fill`, 9px, `.orange` |
| Text | 11px, `theme.primaryText.opacity(0.85)` |
| Padding | 10px horizontal, 7px vertical |

---

## 7. Iconography

### System Symbols

We use SF Symbols exclusively. No custom icon assets except the app icon.

#### Icon Sizing Convention

| Context | Size | Weight |
|---------|------|--------|
| Activity bar | 20px | regular |
| Quick action card | 16px | medium |
| Settings card header | 16px | — (inherits) |
| Feature toggle | 16px | — |
| Inline badges | 9–10px | — |
| Tool chips | 10px | — |
| Dismiss buttons | 10px | bold |
| Section headers | 12px | medium |

### Contextual Icons

| Feature | Icon |
|---------|------|
| Morning Brief | `sunrise.fill` |
| AI Generated | `sparkles` |
| Suggestions | `lightbulb.fill` |
| System Health | `desktopcomputer` |
| Settings | `gearshape.fill` |
| New Chat | `plus.message.fill` |
| Add Context | `doc.badge.plus` |
| Model Store | `square.grid.2x2.fill` |
| Intelligence Core | `cpu.fill` |
| RAG Rewriting | `magnifyingglass` |
| User Personal | `person.text.rectangle.fill` |

---

## 8. Accessibility & Responsiveness

### Minimum Window Size

`800 × 500 px` — enforced via `.frame(minWidth: 800, minHeight: 500)`.

### Color Scheme

Theme-aware via `.preferredColorScheme()`:
- One Light → `.light`
- Dracula → `.dark`
- Others → `nil` (follows system)

### Content Width Constraints

| Component | Max Width |
|-----------|-----------|
| Morning Brief card | 500px |
| WelcomeView content | 520px |
| Agent interrupt banner | 1000px |
| Settings content | None (fills available space) |
| Model fit advisory sheet | 420px |

### Text Selection

Monospaced output in debug logs uses `.textSelection(.enabled)` so users can copy.

### Help Tooltips

All icon-only buttons must have `.help("Description")` for accessibility.

---

## 9. Anti-Patterns (Do NOT Do These)

| Anti-Pattern | Why |
|-------------|-----|
| Hardcoded colors (`Color.gray`, `#hex` in views) | Breaks theme system — always use `theme.*` tokens |
| Custom fonts or typefaces | Breaks native rendering and accessibility scaling |
| Modals for non-critical flows | Interrupts focus — use push navigation instead |
| Spinner without context text | User doesn't know what's loading — always add a label |
| Shadows on dark-on-dark surfaces | Invisible and wastes GPU — check contrast first |
| Animations > 0.5s for routine actions | Feels sluggish — keep routine transitions under 0.3s |
| `Color.black` for shadows | Doesn't adapt to themes — use `theme.primaryText.opacity(N)` |
| `.animation()` without `value:` | Deprecated and causes unexpected animations on unrelated state changes |
| Inline `@State` for persisted preferences | Use `@AppStorage(AppSettings.key)` for anything that survives app restart |
| `NavigationView` / `NavigationStack` | We use custom `MainViewRouter` stack — mixing causes conflicts |

---

## 10. File Organization

### View Files

```
Interfaces/
├── Main/
│   ├── Views/
│   │   ├── WelcomeView.swift              ← Landing screen
│   │   ├── MainApplicationView.swift       ← Root layout
│   │   ├── Conversation/                   ← Chat-related views
│   │   ├── Sidebar/
│   │   │   ├── Settings/                   ← All settings views
│   │   │   └── Explorer/                   ← File explorer + Theme
│   │   └── BackendProfile/                 ← Model pickers, stores
│   ├── MainViewRouter.swift                ← Navigation state
│   └── MainApplicationViewModel.swift      ← Central ViewModel
├── Shared/
│   └── Chat/                               ← ChatMessage, ChatBubble
```

### Intelligence Features

```
Intelligence/
└── MorningBrief/
    ├── MorningBriefModels.swift             ← Data models
    ├── MorningBriefSource.swift             ← Source protocol
    ├── MorningBriefService.swift            ← Orchestrator
    ├── MorningBriefCardView.swift           ← UI card
    └── Sources/
        ├── RecentConversationSource.swift   ← Conversation context
        └── SystemHealthSource.swift         ← Hardware status
```

Future Intelligence features should follow this pattern: `Intelligence/<FeatureName>/` with models, service, and view files co-located.

---

## 11. Checklist for New Views

Before merging any new UI:

- [ ] Uses `@Environment(\.appTheme) private var theme` — no hardcoded colors
- [ ] All fonts from the typography scale — no arbitrary sizes
- [ ] Corner radii from the scale (4/6/8/10/12/16) — no random values
- [ ] Shadows use `theme.primaryText.opacity(N)` — not `Color.black`
- [ ] Borders use `theme.surfaceOverlayStrong` — consistent weight (0.5 or 1px)
- [ ] Hover states on interactive cards — `onHover` with `easeOut(0.2)` animation
- [ ] Spring animations for entrances — `response: 0.3–0.45, dampingFraction: 0.8`
- [ ] `.help()` tooltip on icon-only buttons
- [ ] Navigation via `MainViewRouter` — no `NavigationLink` or `sheet()` for full-page destinations
- [ ] Persistent state via `@AppStorage(AppSettings.key)` — not raw `UserDefaults` in views
- [ ] AI content has an "AI" badge and dismiss button
- [ ] Loading states show descriptive text, not just a spinner

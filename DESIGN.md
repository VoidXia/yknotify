# Design System — yknotify

## Product Context
- **What this is:** macOS menu bar utility that detects when a YubiKey is waiting for touch and notifies the user
- **Who it's for:** Security-aware developers who use YubiKey for FIDO2, OpenPGP (SSH, Git signing, GPG)
- **Space/industry:** Developer tools, security utilities
- **Project type:** macOS native menu bar app (Swift, Cocoa, no web UI)

## Aesthetic Direction
- **Direction:** Native macOS — follows Apple Human Interface Guidelines
- **Decoration level:** Minimal — system chrome does the work
- **Mood:** Quietly competent. The app should feel like it belongs in macOS, not like a third-party bolt-on. Unobtrusive when idle, clearly actionable when active.

## Interaction Model
- **Left-click:** Triggers `ssh -o BatchMode=yes -o ConnectTimeout=5 git@github.com` in the background. Forces SSH auth, which exercises the YubiKey and surfaces the touch prompt on demand. Gated so concurrent clicks don't spawn duplicates; ConnectTimeout caps any hang.
- **Right-click (or ctrl+left-click):** Context menu (Preferences, Quit)
- **Menu bar icon:** SF Symbol `key` (idle), red rounded badge with `key.fill` glyph and blinking alpha (touch needed)
- **Click feedback:** Brief alpha dim-and-restore (~400ms total) confirms the left-click registered before the SSH process spawns. Suppressed while pulsing so it doesn't fight the touch animation.

## Notification Strategy
- **Delivery:** macOS native via `UNUserNotificationCenter`
- **Title:** "YubiKey Touch Needed"
- **Body:** Operation-specific — "FIDO2 authentication waiting" or "OpenPGP operation waiting"
- **Frequency:** One notification per touch-needed event, no spam
- **Auto-dismiss:** Clear notification when touch is detected (stopQueue / new CryptoTokenKit message)
- **Sound:** Optional, off by default. Subtle metallic tap, not the default macOS alert sound.
- **Priority:** Time-sensitive delivery to bypass Focus modes (the user chose to install a YubiKey touch notifier — they want to be notified)

## Preferences Window

### Architecture
- Separate NSWindow, not in-popover. Popover stays fast and focused on status.
- Standard macOS window chrome with toolbar tabs
- Toolbar icon style: SF Symbols in tab buttons

### Tabs
1. **General**
   - Start at login (toggle, uses SMAppService)

2. **Notifications**
   - Show notification banner (toggle, default: on)
   - Play sound (toggle, default: off)
   - Sound selection (dropdown, only visible when sound is on)

3. **Monitoring**
   - Watch FIDO2 events (toggle, default: on)
   - Watch OpenPGP events (toggle, default: on)
   - Safety timeout slider (10s–60s, default: 30s) — auto-dismiss pulse after this duration

4. **History**
   - Retention period (dropdown: Today only / 7 days / 30 days / Never)
   - Clear history button

### Persistence
- UserDefaults for all preferences
- History stored in UserDefaults (small data, no need for SQLite)

## Color
- **Approach:** Restrained — system colors throughout, one semantic accent
- **Active state accent:** System amber (`#FF9F0A` / NSColor.systemOrange adjacent) — "attention needed, not emergency"
- **Idle state:** System green for badge
- **All other colors:** macOS system defaults (`.labelColor`, `.secondaryLabelColor`, `.separatorColor`, `.controlAccentColor`)
- **Dark/light mode:** Automatic via system colors. No custom dark mode implementation needed.
- **Why amber for active:** Red is too alarming for a routine action (touching your key is normal). Blue is too neutral (it needs attention). Amber says "act when ready" — the same register as a yellow traffic light.

## Typography
- **Font:** San Francisco (system font) — `-apple-system` / `NSFont.systemFont`
- **No custom fonts.** Native macOS app uses the system font. Period.
- **Scale:** Standard macOS text styles
  - App name in header: 13px semibold
  - Badge text: 11px semibold
  - History item type: 13px medium
  - History timestamp: 12px regular, secondary color, tabular-nums
  - Touch card operation: 15px semibold
  - Touch card hint: 13px regular, amber
  - Preference labels: 13px regular
  - Preference sublabels: 12px regular, tertiary color
  - Group titles: 12px semibold uppercase, tertiary color

## Spacing
- **Base unit:** 4px (macOS standard)
- **Popover padding:** 12–16px
- **History item vertical padding:** 6px
- **Section spacing:** 20px between preference groups
- **Touch card padding:** 20px vertical, 16px horizontal

## Motion
- **Menu bar icon (touch needed):** 1Hz blink, alpha toggles 0.2 ↔ 1.0
- **Click feedback:** alpha dips to 0.35 (150ms ease) then back to 1.0 (250ms ease). Suppressed during pulse.
- **Safety timeout:** 30s default. After timeout, reset to idle with no animation.
- **All other motion:** Standard macOS control animations (toggle switches, etc.)

## Icon States
| State | SF Symbol | Behavior |
|-------|-----------|----------|
| Idle | `key` (outline) | Static, full opacity |
| Touch needed | `key.fill` (filled) | Sine pulse, alpha 0.25–1.0 at 1Hz |

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-31 | Initial design system created | Created by /design-consultation for UI expansion: popover + notifications + preferences |
| 2026-03-31 | Amber for active state | Red too alarming for routine action, blue too neutral. Amber = "attention, not emergency." |
| 2026-03-31 | Operation type in notifications | Security-aware audience wants to know why their key is asking — FIDO2 vs OpenPGP |
| 2026-03-31 | Preferences in separate window | Keeps popover fast/focused on status. Settings are infrequent. |
| 2026-03-31 | Touch history feature | No YubiKey tool shows this. Gives audit visibility ("did I touch for that SSH session?") |
| 2026-03-31 | UserDefaults for persistence | Small data volume (preferences + recent history). SQLite is overkill. |
| 2026-04-25 | Left-click triggers SSH refresh, removed popover | Popover was specced but never wired up (left/right both showed menu). Replaced left-click with on-demand SSH-to-GitHub to manually exercise the YubiKey — useful for refreshing SSH auth and verifying yknotify's detection without waiting for an organic touch event. Right-click keeps the menu. |

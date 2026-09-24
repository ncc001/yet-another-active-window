# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.1.0

### Added
- **Vertical layout support** for the Active Window widget. When the bar is in vertical orientation:
  - Window icon displayed centered at the top
  - Window title positioned below the icon
  - Horizontal marquee for overflowing titles (works in both orientations)
  - Focused window indicator
  - Configurable spacing between entries
  - Adaptive icon sizing (`effectiveIconSize`) that shrinks to fit available space (minimum 12px)
- New `effectiveIconSize` property that adapts icon size in vertical mode to leave room for the title
- Vertical spacing now uses the configured spacing setting (2-8px)

### Changed
- **Icon resolution system** rewritten for compatibility with current Quickshell/Omarchy versions:
  - Removed the legacy `/proc/<pid>/exe` fallback mechanism (PID cache, batched process probing)
  - Added generic identity-based fallback using `Quickshell.iconPath(candidate)` for windows without DesktopEntry matches
  - Final fallback to `application-x-executable` generic icon
  - Icon cache revision no longer includes PID cache revision
- Horizontal-specific settings now hidden in vertical mode:
  - Maximum widget width slider
  - Focused title width slider
- Spacing setting maximum reduced from 12px to 8px
- Removed unused `Quickshell.Io` import
- Title clip positioning fixed in horizontal mode (was offset outside visible area)

### Fixed
- Title rendering in horizontal mode: the `titleClip` was positioned at `y = entry.glyphSlot` (28px) with height 28px, placing it completely outside the visible Entry area. Now correctly uses `y: 0` in horizontal mode.
- Marquee now works in both horizontal and vertical orientations (was horizontal-only)

### Technical
- Cleaned up ~90 lines of dead code (PID/executable fallback machinery)
- Simplified icon resolution path with fewer branches
- Single marquee implementation for both orientations

## [Unreleased]
# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); `oss release` reads the
`## [version]` sections.

## [Unreleased]

## [0.2.2] - 2026-11-24

### Changed
- The Accessibility grant survives updates: installing signs the app with a certificate made on your Mac, and clears the dead entry of an older build so macOS asks one last time
- Homebrew: `sesam-install` copies and signs the app, instead of `cp -R`, and the `sesam` command runs the installed copy

## [0.2.1] - 2026-11-22

### Changed
- README: correct the test count to 203 and say the clipboard and idle timeouts are defaults

## [0.2.0] - 2026-11-22

### Added
- Install with Homebrew: `brew install john-athan/tap/sesam`
- `make uninstall` removes the app, the `sesam` link and the one file Sesam writes

### Changed
- Build, test and install come from the files every Swift app in the fleet shares

## [0.1.3] - 2026-11-22

### Fixed
- CFBundleVersion matches the release version again
- README: the Accessibility grant breaks on every update, not only on a rebuild

## [0.1.2] - 2026-11-16

### Changed
- New app icon: the cave door ajar, gold light spilling out

## [0.1.1] - 2026-10-18

### Fixed
- Every spelling of an IPv4 literal is rejected as an icon host
- Three crashes and a race found on read

## [0.1.0] - 2026-09-13

- First release: menu bar app and search panel over 1Password and KeePassXC, with one-time codes, writing to vaults, Touch ID for the master password and optional site icons

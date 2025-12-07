# GlabToggl

Track Toggl timers straight from the GitLab issues assigned to you. GlabToggl adds a small menubar helper that lists your assigned issues, starts Toggl timers with one click, and lets you stop the current timer without leaving your keyboard.

## What it does
- Pulls your open GitLab issues (assigned to you) and caches them for quick access.
- Opens an issue chooser so you can start a Toggl timer named `"<issue title> #<iid>"`.
- Optionally copies the selected issue URL to your clipboard when you start tracking.
- Shows menubar status: idle vs. tracking a specific issue; menu lists the cached issues.
- Provides a hotkey to stop the currently running Toggl timer.

## Requirements
- Hammerspoon (tested with `hs.spoons`).
- Toggl API token and workspace ID.
- GitLab personal access token (scope `read_api` is enough for listing issues).

## Installation
1. Copy `GlabToggl.spoon` into `~/.hammerspoon/Spoons/`.
2. Load and configure the spoon from your `~/.hammerspoon/init.lua` (or a dedicated module).

Example:

```lua
hs.loadSpoon("GlabToggl")

local secrets = dofile(os.getenv("HOME") .. "/.hammerspoon/secrets.lua")

spoon.GlabToggl:configure({
  assignee          = "your.gitlab.username",
  togglApiToken     = secrets.togglApiToken,
  togglWorkspaceId  = secrets.togglWorkspaceId,
  gitlabToken       = secrets.gitlabToken,
  -- gitlabBase      = "https://gitlab.com/api/v4", -- override for self-hosted
  -- copyUrlOnSelect = true,
  -- issuesCacheTTL  = 3600, -- seconds; 0 disables cache expiry
})
:bindHotkeys({
  openChooser = {{"cmd", "alt", "ctrl"}, "I"},
  stopCurrent = {{"cmd", "alt", "ctrl"}, "O"},
})
:start()
```

## Usage
- `openChooser` hotkey: shows your assigned GitLab issues; picking one starts a Toggl timer and (optionally) copies the issue URL.
- `stopCurrent` hotkey: stops the currently running Toggl timer.
- Menubar shows `GlabToggl: tracking` while a timer is running and lists cached issues in the dropdown.

## Configuration
All options are passed to `GlabToggl:configure({...})`:

| Option | Description | Default |
| --- | --- | --- |
| `togglApiToken` | Toggl API token | required |
| `togglWorkspaceId` | Toggl workspace ID | required |
| `gitlabToken` | GitLab personal access token | required |
| `gitlabBase` | GitLab API base URL (use your self-hosted URL if needed) | `https://gitlab.com/api/v4` |
| `copyUrlOnSelect` | Copy issue URL to clipboard after starting a timer | `true` |
| `issuesCacheTTL` | Seconds to cache assigned issues (set `0` to always fetch fresh) | `3600` |

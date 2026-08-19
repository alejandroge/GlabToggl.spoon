--- === GlabToggl ===
---
--- Track Toggl timers from assigned GitLab issues via a menubar helper.
local obj = {}
obj.__index = obj

obj.name = "GlabToggl"
obj.version = "0.1"
obj.author = "Alejandro Guevara <alejandro.guevara.esc@gmail.com>"
obj.homepage = "local"
obj.license = "MIT - https://opensource.org/licenses/MIT"

----------------------------------------------------------------
-- Defaults (override via obj:configure({...}) in init.lua)
----------------------------------------------------------------
obj.config = {
    togglApiToken     = "",
    togglWorkspaceId  = "",
    gitlabToken       = "",
    gitlabBase        = "https://gitlab.com/api/v4",
    -- copy gitlab URL to clipboard, after selecting an issue to start a timer for
    copyUrlOnSelect   = true,
    textTasks         = {},
    -- seconds; 0 disables cache expiration
    issuesCacheTTL    = 10,
    idleReminderEnabled = true,
    idleReminderInterval = 300,
    idleReminderStartTime = "09:30",
    idleReminderEndTime = "18:00",
    idleReminderWeekdaysOnly = true,
    idleReminderAlertDuration = 8,
}

local logger = hs.logger.new("GlabToggl", "info")

local menubarIdleTitle = "GT ○"
local menubarTrackingTitle = "GT ●"
local menubarErrorTitle = "GT ⚠"

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function containsIgnoreCase(value, query)
    value = string.lower(value or "")
    query = string.lower(query or "")
    return value:find(query, 1, true) ~= nil
end

----------------------------------------------------------------
-- Third-party calls
----------------------------------------------------------------
local function iso_now_utc()
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

local function togglAuthHeader(cfg)
    if not cfg.togglApiToken then return nil end
    if cfg.togglApiToken == "" then return nil end

    return "Basic " .. hs.base64.encode(cfg.togglApiToken .. ":api_token")
end

local function parseInt(h) return (h and h ~= "" and tonumber(h)) or nil end

local function startTogglTimer(self, cfg, desc, callback)
    local auth = togglAuthHeader(cfg)

    local url = ("https://api.track.toggl.com/api/v9/workspaces/%s/time_entries"):format(cfg.togglWorkspaceId)
    local bodyTbl = {
        description   = desc,
        created_with  = cfg.createdWith,
        start         = iso_now_utc(),
        duration      = -1, -- running entry
        workspace_id  = tonumber(cfg.togglWorkspaceId),
        billable      = false,
        created_with  = "hammerspoon (GlabToggl)",
    }
    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = auth,
    }
    local body = hs.json.encode(bodyTbl, true)
    hs.http.doAsyncRequest(url, "POST", body, headers, function(status, resp, _)
        if status >= 200 and status < 300 then
            logger.i("Started: " .. (desc or ""))
            if callback then callback(true) end
        else
            logger.i("Response: " .. (resp or ""))
            if callback then callback(false) end
        end
    end)
end

local function getCurrentTogglTimer(cfg, callback)
    local auth = togglAuthHeader(cfg)
    local currentTimeEntryUrl = "https://api.track.toggl.com/api/v9/me/time_entries/current"
    local headers = {
        ["Authorization"] = auth,
        ["Content-Type"] = "application/json",
    }

    hs.http.doAsyncRequest(currentTimeEntryUrl, "GET", nil, headers, function(status, resp, _)
        if status < 200 or status >= 300 then
            callback(false, nil, status, resp)
            return
        end

        local running = hs.json.decode(resp) or nil
        if not running or running.duration >= 0 then
            callback(true, nil, status, resp)
            return
        end

        callback(true, running, status, resp)
    end)
end

local function stopTogglTimer(self, cfg, callback)
    local auth = togglAuthHeader(cfg)
    local headers = {
        ["Authorization"] = auth,
        ["Content-Type"] = "application/json",
    }

    getCurrentTogglTimer(cfg, function(success, running, status, resp)
        if not success then
            hs.alert.show("Toggl list error " .. status)
            logger.e("Failed to get current time entry: " .. tostring(resp))
            callback(false)
            return
        end

        if not running then
            callback(true)
            return
        end

        local stopUrl = (
            "https://api.track.toggl.com/api/v9/workspaces/%s/time_entries/%s/stop"
        ):format(cfg.togglWorkspaceId, running.id)

        hs.http.doAsyncRequest(
            stopUrl,
            "PATCH",
            "{}",
            headers,
            function(st, _, _)
                if st >= 200 and st < 300 then
                    callback(true)
                else
                    hs.alert.show("Stop failed " .. st)
                    logger.e("Failed to stop time entry: " .. tostring(st))
                    callback(false)
                end
            end
        )
    end)
end

local function gitlabAuthHeaders(cfg)
    if not cfg.gitlabToken then return nil end
    if cfg.gitlabToken == "" then return nil end

    return "Bearer " .. cfg.gitlabToken
end

local function parseIssues(raw)
    local decoded = hs.json.decode(raw) or {}
    local choices = {}
    for _, it in ipairs(decoded) do
        local title = it.title or "(no title)"
        local iid   = it.iid
        local url   = it.web_url or it.webUrl
        local proj  = (it.references and it.references.full)
        or (it.project and it.project.path_with_namespace)
        or (it.references and it.references.relative)
        or ""
        local labels = ""
        if type(it.labels) == "table" and #it.labels > 0 then
            labels = table.concat(it.labels, ", ")
        end
        local sub = string.format("GitLab issue · #%s", tostring(iid or "?"))
        if labels ~= "" then
            sub = sub .. " · " .. labels
        end
        table.insert(choices, {
            text        = title,
            subText     = sub,
            url         = url,
            projectPath = proj,
            iid         = iid,
        })
    end
    return choices
end

local function textTaskChoice(description, subText)
    return {
        text = description,
        subText = subText or "Text task",
        description = description,
        _textTask = true,
    }
end

local function statusChoice(text, sub)
    return { text = text, subText = sub or "", _status = true }
end

local function getTextTaskChoices(cfg)
    local choices = {}

    for _, task in ipairs(cfg.textTasks or {}) do
        local description = nil
        local subText = "Text task"

        if type(task) == "string" then
            description = trim(task)
        elseif type(task) == "table" then
            description = trim(task.text or task.description or task.title)
            subText = task.subText or task.subtitle or subText
        end

        if description ~= "" then
            table.insert(choices, textTaskChoice(description, subText))
        end
    end

    return choices
end

local function appendChoices(target, choices)
    for _, choice in ipairs(choices or {}) do
        table.insert(target, choice)
    end
end

local function filterChoices(choices, query)
    query = trim(query)
    if query == "" then return choices or {} end

    local filtered = {}
    for _, choice in ipairs(choices or {}) do
        if not choice._status and containsIgnoreCase(choice.text, query) then
            table.insert(filtered, choice)
        end
    end

    return filtered
end

local function hasMatchingChoice(choices, query)
    query = trim(query)
    if query == "" then return true end

    for _, choice in ipairs(choices or {}) do
        if not choice._status and containsIgnoreCase(choice.text, query) then
            return true
        end
    end

    return false
end

local function chooserChoices(cfg, gitlabIssues, query)
    local choices = {}
    local textTasks = getTextTaskChoices(cfg)
    local filteredTextTasks = filterChoices(textTasks, query)
    local filteredGitlabIssues = filterChoices(gitlabIssues, query)
    query = trim(query)

    if query ~= "" and not hasMatchingChoice(textTasks, query) and not hasMatchingChoice(gitlabIssues, query) then
        table.insert(choices, textTaskChoice(query, "Typed text task"))
    end

    appendChoices(choices, filteredTextTasks)
    appendChoices(choices, filteredGitlabIssues)

    if #choices == 0 then
        table.insert(choices, statusChoice("No configured text tasks or assigned GitLab issues"))
    end

    return choices
end

local function cacheKey(cfg)
    return cfg.issuesCacheKey or (obj.name .. ".issuesCache")
end

local function saveIssuesToCache(cfg, raw)
    local key = cacheKey(cfg)
    local ok, err = pcall(function()
        hs.settings.set(key, {
            raw = raw,
            fetchedAt = os.time(),
        })
    end)
    if not ok then logger.i("Failed to persist issues cache: " .. tostring(err)) end
end

local function fetchIssues(cfg, onSuccess, onError)
    local auth = gitlabAuthHeaders(cfg)
    local base = cfg.gitlabBase:gsub("/+$","")
    local url  = base .. "/issues"

    local qs = {
        "state=opened",
        "order_by=updated_at",
        "per_page=100",
        "scope=assigned_to_me",
    }

    local results = {}

    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = auth,
    }

    local function reportError(status, body)
        local msg = "GitLab API error " .. tostring(status)
        hs.alert.show(msg)
        logger.e(("%s body: %s"):format(msg, body or "(nil)"))
        if onError then onError(msg) end
    end

    local full = url .. "?" .. table.concat(qs, "&")
    hs.http.asyncGet(full, headers, function(status, body, headers)
        if status < 200 or status >= 300 then
            reportError(status, body)
            return
        end
        local chunk = hs.json.decode(body) or {}
        for _, it in ipairs(chunk) do table.insert(results, it) end

        if onSuccess then onSuccess(hs.json.encode(results)) end
    end)
end

local function getCachedIssuesRaw(cfg)
    local key = cacheKey(cfg)
    local ok, entry = pcall(function() 
        return hs.settings.get(key)
    end)

    if not ok then
        logger.i("Failed to read issues cache: " .. tostring(entry))
        return nil, true
    end

    if type(entry) ~= "table" or type(entry.raw) ~= "string" then return nil end

    local ttl = cfg.issuesCacheTTL
    local isFresh = false

    if ttl and ttl > 0 and entry.fetchedAt then
        local age = os.time() - (entry.fetchedAt or 0)
        isFresh = age <= ttl
    end

    return entry.raw, not isFresh
end

local function parseTimeOfDay(value)
    if type(value) ~= "string" then return nil end

    local hour, minute = value:match("^(%d%d?):(%d%d)$")
    hour = tonumber(hour)
    minute = tonumber(minute)

    if not hour or not minute then return nil end
    if hour < 0 or hour > 23 then return nil end
    if minute < 0 or minute > 59 then return nil end

    return hour * 60 + minute
end

local function isWithinIdleReminderWindow(cfg)
    local now = os.date("*t")

    if cfg.idleReminderWeekdaysOnly and (now.wday == 1 or now.wday == 7) then
        return false
    end

    local startMinutes = parseTimeOfDay(cfg.idleReminderStartTime)
    local endMinutes = parseTimeOfDay(cfg.idleReminderEndTime)

    if not startMinutes or not endMinutes then
        logger.e("Invalid idle reminder time window")
        return false
    end

    local currentMinutes = now.hour * 60 + now.min
    return currentMinutes >= startMinutes and currentMinutes < endMinutes
end

local function getGitlabIssues(cfg, onSuccess)
    local cachedIssues, shouldFetch = getCachedIssuesRaw(cfg)

    if shouldFetch then
        logger.i("No valid cached GitLab issues found; fetching latest")

        fetchIssues(cfg, function(raw)
            saveIssuesToCache(cfg, raw)
            local freshChoices = parseIssues(raw)

            logger.i("fetched...." .. tostring(#freshChoices) .. " issues")
            if #freshChoices <= 0 then
                logger.i("No assigned GitLab issues", "Just refreshed")
            end
            onSuccess(freshChoices)
        end, function(err)
            if cachedChoices and #cachedChoices > 0 then return end
            logger.i("Unable to load GitLab issues", err or "Request failed")
        end)
    else
        logger.i("Using cached GitLab issues")
        local parsedIssues = cachedIssues and parseIssues(cachedIssues) or nil
        onSuccess(parsedIssues)
    end
end

----------------------------------------------------------------
-- Internals
----------------------------------------------------------------
obj._menubarItem = nil
obj._currentTimerDescription = nil
obj._runningGitlabIssue = nil
obj._idleReminderTimer = nil
obj._idleReminderNotification = nil

function obj:_ensureStatusItem()
    if not self._menubarItem then
        self._menubarItem = hs.menubar.new()
    end
    return self._menubarItem
end

function obj:_setMenubarItemStatus(runningGitlabIssue)
    local item = self:_ensureStatusItem()
    if not item then return end

    if not runningGitlabIssue then
        item:setTitle(menubarIdleTitle)
        item:setTooltip("No timer running")
    else
        local desc = runningGitlabIssue
        if type(runningGitlabIssue) == "table" then
            desc = runningGitlabIssue.text or runningGitlabIssue.description or "Toggl timer"
            if runningGitlabIssue.iid then
                desc = string.format("%s #%s", desc, tostring(runningGitlabIssue.iid))
            end
        end

        item:setTitle(menubarTrackingTitle)
        item:setTooltip("Tracking: " .. tostring(desc))
    end
end

function obj:_trackGitlabIssue(issue)
    if not issue or issue._status then return end
    if issue._textTask then
        self:_trackDescription(issue.description or issue.text)
        return
    end

    local desc = string.format("%s #%s", issue.text, tostring(issue.iid or ""))

    local cfg = self.config

    startTogglTimer(self, cfg, desc, function(success)
        if success then
            obj._runningGitlabIssue = issue

            if cfg.copyUrlOnSelect and issue.url then
                hs.pasteboard.setContents(issue.url)
            end

            self:_setMenubarItemStatus(issue)
        end
    end)
end

function obj:_trackDescription(desc)
    desc = trim(desc)
    if desc == "" then return end

    local cfg = self.config

    startTogglTimer(self, cfg, desc, function(success)
        if success then
            self._runningGitlabIssue = nil
            self:_setRunningDescription(desc)
        end
    end)
end

function obj:_setMenubarItemIssuesList(gitlabIssues)
    local item = self:_ensureStatusItem()
    if not item then return end

    local textTasks = getTextTaskChoices(self.config)

    if #textTasks > 0 or (gitlabIssues and #gitlabIssues > 0) then
        local menuItems = {}

        if #textTasks > 0 then
            table.insert(menuItems, { title = "Text Tasks", disabled = true })
        end
        for _, issue in ipairs(textTasks) do
            table.insert(menuItems, {
                title = issue.text,
                fn = function() self:_trackGitlabIssue(issue) end,
            })
        end

        if gitlabIssues and #gitlabIssues > 0 then
            if #menuItems > 0 then table.insert(menuItems, { title = "-" }) end
            table.insert(menuItems, { title = "GitLab Issues", disabled = true })
        end
        for _, issue in ipairs(gitlabIssues or {}) do
            table.insert(menuItems, {
                title = issue.text .. " #" .. tostring(issue.iid or ""),
                fn = function() self:_trackGitlabIssue(issue) end,
            })
        end

        item:setMenu(menuItems)
    else
        item:setMenu({
            { title = "No configured text tasks or assigned GitLab issues", disabled = true },
        })
    end
end

function obj:_setRunningDescription(desc)
    self._currentTimerDescription = desc
    self:_setMenubarItemStatus(desc)
end

function obj:_showIdleReminder()
    hs.alert.show("No Toggl timer running", self.config.idleReminderAlertDuration)

    self._idleReminderNotification = hs.notify.new(function()
        self:openChooser()
    end, {
        title = "No Toggl timer running",
        informativeText = "What are you working on?",
        withdrawAfter = 0,
    })

    self._idleReminderNotification:send()
end

function obj:_checkIdleReminder()
    local cfg = self.config

    if not cfg.idleReminderEnabled then return end
    if not isWithinIdleReminderWindow(cfg) then return end

    getCurrentTogglTimer(cfg, function(success, running, status, resp)
        if not success then
            logger.e("Idle reminder failed to get current time entry: " .. tostring(status) .. " " .. tostring(resp))
            return
        end

        if running then
            self._runningGitlabIssue = nil
            self:_setRunningDescription(running.description or "Toggl timer")
            return
        end

        self._runningGitlabIssue = nil
        self._currentTimerDescription = nil
        self:_setMenubarItemStatus(nil)
        self:_showIdleReminder()
    end)
end

function obj:_startIdleReminderTimer()
    if self._idleReminderTimer then
        self._idleReminderTimer:stop()
        self._idleReminderTimer = nil
    end

    local cfg = self.config
    if not cfg.idleReminderEnabled then return end
    if not cfg.idleReminderInterval or cfg.idleReminderInterval <= 0 then return end

    self._idleReminderTimer = hs.timer.new(cfg.idleReminderInterval, function()
        self:_checkIdleReminder()
    end)
    self._idleReminderTimer:start()
end

local function getConfigErrors(cfg)
    local errors = {}

    if not cfg.togglApiToken or cfg.togglApiToken == "" then
        table.insert(errors, "togglApiToken is required")
    end

    if not cfg.togglWorkspaceId or cfg.togglWorkspaceId == "" then
        table.insert(errors, "togglWorkspaceId is required")
    end

    if not cfg.gitlabToken or cfg.gitlabToken == "" then
        table.insert(errors, "gitlabToken is required")
    end

    return errors
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------
--- GlabToggl:configure(o) -> GlabToggl
--- Method
--- Configures the GlabToggl spoon
---
--- Parameters:
--- * o - A table containing configuration parameters.
---  * togglApiToken - (string) Your Toggl API token
---  * togglWorkspaceId - (string) Your Toggl workspace ID
---  * gitlabToken - (string) Your GitLab personal access token
---  * gitlabBase - (string) Base URL for GitLab API (default: "https://gitlab.com/api/v4")
---  * copyUrlOnSelect - (boolean) Copy GitLab issue URL to clipboard after selecting an issue to start a timer for
---    (default: true)
---  * textTasks - (table) Text-only Toggl tasks to show separately from GitLab issues, e.g. {"Meetings", "Support Engineer"}
---    (default: {})
---  * issuesCacheTTL - (number) Number of seconds to cache GitLab issues; 0 disables cache expiration (default: 3600)
---  * idleReminderEnabled - (boolean) Check whether a Toggl timer is running during work hours (default: true)
---  * idleReminderInterval - (number) Seconds between idle reminder checks (default: 300)
---  * idleReminderStartTime - (string) Local start time for reminders in HH:MM format (default: "09:30")
---  * idleReminderEndTime - (string) Local end time for reminders in HH:MM format (default: "18:00")
---  * idleReminderWeekdaysOnly - (boolean) Only remind Monday-Friday using system timezone (default: true)
---  * idleReminderAlertDuration - (number) Seconds to keep the on-screen alert visible (default: 8)
---
--- Returns:
--- * The `GlabToggl` spoon object
function obj:configure(o)
    for k,v in pairs(o or {}) do self.config[k] = v end
    return self
end

--- GlabToggl:start() -> none
--- Method
--- Starts the GlabToggl spoon
---
--- Parameters:
--- * None
---
--- Returns:
--- * The `GlabToggl` spoon object
function obj:start()
    local errors = getConfigErrors(self.config)
    if #errors > 0 then
        local item = self:_ensureStatusItem()
        item:setTitle(menubarErrorTitle)
        item:setTooltip("Some issues were found in the GlabToggl configuration")

        local menuItems = {}
        for _, err in ipairs(errors) do
            logger.e("Configuration error: " .. err)
            table.insert(menuItems, { title = err, disabled = true })
        end

        table.insert(menuItems, { title = "-" }) -- separator
        table.insert(menuItems, { title = "Please update the configuration", disabled = true })

        item:setMenu(menuItems)
        return
    end

    self._runningGitlabIssue = nil
    self:_setMenubarItemStatus(nil)
    self._menubarItem:setClickCallback(function()
        local cfg = self.config

        local gitlabIssues = {}
        getGitlabIssues(cfg, function(gitlabIssues)
            self:_setMenubarItemIssuesList(gitlabIssues)
            return self
        end)
    end)
    self:_startIdleReminderTimer()

    return self
end

--- GlabToggl:openChooser() -> none
--- Method
--- Opens a chooser to select a GitLab issue, configured text task, or typed text to start a Toggl timer for
---
--- Parameters:
--- * None
---
--- Returns:
--- * The `GlabToggl` spoon object
function obj:openChooser()
    local cfg = self.config

    local gitlabIssues = {}
    getGitlabIssues(cfg, function(gitlabIssues)
        local c = hs.chooser.new(function(selectedTask)
            obj:_trackGitlabIssue(selectedTask)
        end)

        self:_setMenubarItemIssuesList(gitlabIssues)

        c:placeholderText("Select a task or type a new one")
        c:choices(chooserChoices(cfg, gitlabIssues, ""))
        c:queryChangedCallback(function(query)
            c:choices(chooserChoices(cfg, gitlabIssues, query))
        end)

        c:show()
    end)

    return self
end

--- GlabToggl:stopCurrent() -> none
--- Method
--- Stops the currently running Toggl timer
---
--- Parameters:
--- * None
---
--- Returns:
--- * The `GlabToggl` spoon object
function obj:stopCurrent()
    local cfg = self.config
    stopTogglTimer(self, cfg, function(success)
        if success then
            self._runningGitlabIssue = nil
            self:_setMenubarItemStatus(nil)
        end
    end)

    return self
end

--- GlabToggl:bindHotkeys(mapping) -> GlabToggl
--- Method
--- Binds hotkeys for GlabToggl commands
---
--- Parameters:
--- * mapping - A table containing hotkey modifier/key details for the following commands:
---  * openChooser - Opens the GitLab issue chooser
---  * stopCurrent - Stops the currently running Toggl timer
---
--- Returns:
---  * The `GlabToggl` spoon object
function obj:bindHotkeys(mapping)
    local spec = {
        openChooser = function() self:openChooser() end,
        stopCurrent = function() self:stopCurrent() end,
    }
    hs.spoons.bindHotkeysToSpec(spec, mapping or {})
    return self
end

return obj

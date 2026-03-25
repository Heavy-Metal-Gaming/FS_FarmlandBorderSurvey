---
--- PropertyBorders.lua
--- Main entry point for the Property Borders mod (FS25).
---
--- Adds glowing border lines around owned farmlands in the 3D world.
--- Settings are injected into the existing Game Settings page.
--- Settings persist to disk as modSettings/PropertyBorders.xml.
---

-- Load sub-modules
local modDir = g_currentModDirectory
source(modDir .. "scripts/BorderScanner.lua")
source(modDir .. "scripts/BorderRendererDebug.lua")
source(modDir .. "scripts/BorderRendererMesh.lua")
source(modDir .. "scripts/events/PropertyBordersSettingsEvent.lua")
source(modDir .. "scripts/events/PropertyBordersSettingsInitialEvent.lua")

PropertyBorders = {}
PropertyBorders.modDir = modDir
PropertyBorders.modName = g_currentModName

-- Default settings
PropertyBorders.settings = {
    color        = {0.2, 0.8, 1.0, 0.4},
    contractColor = {1.0, 0.6, 0.1, 0.5},
    height       = 0.3,
    renderMode   = "mesh",  -- "mesh" or "debug"
    visible      = false,
    displayScope = "owned",  -- "owned", "contracted", "all"
}

-- Runtime state
PropertyBorders.borderCache = {}          -- farmlandId -> list of world-coord polylines
PropertyBorders.contractBorderCache = {}  -- farmlandId -> list of world-coord polylines
PropertyBorders.isInitialized = false
PropertyBorders.inputRegistered = false
PropertyBorders.toggleEventId = nil
PropertyBorders.contractRefreshTimer = 0
PropertyBorders.CONTRACT_REFRESH_INTERVAL = 30000  -- 30 seconds in ms
PropertyBorders.SIMPLIFY_TOLERANCE = 1.5           -- Douglas-Peucker tolerance in bitmap units
PropertyBorders.STRIP_WIDTH = 0.3                  -- Width of mesh strips in meters

-- Custom notification overlay state
PropertyBorders.notificationText    = nil     -- text to display, or nil
PropertyBorders.notificationEndTime = 0       -- g_time when it expires (ms)
PropertyBorders.NOTIFICATION_DURATION = 2000  -- display duration (ms)
PropertyBorders.NOTIFICATION_FADE    = 400    -- fade-out tail (ms)
-- HUD-style background overlays (created lazily from g_overlayManager)
PropertyBorders.notifBgScale         = nil    -- center stretch overlay
PropertyBorders.notifBgLeft          = nil    -- left cap overlay
PropertyBorders.notifBgRight         = nil    -- right cap overlay
PropertyBorders.isBorderDimmed       = false  -- true when HUD hidden and glow reduced

-- Settings menu items list (order matters for menu display)
PropertyBorders.menuItems = {
    "visible",
    "renderMode",
    "displayScope",
    "height",
    "colorPreset",
}

-- Settings definitions for the menu system
PropertyBorders.SETTINGS = {}
PropertyBorders.CONTROLS = {}

---------------------------------------------------------------------------
-- Settings definitions (populated after l10n is available)
---------------------------------------------------------------------------
function PropertyBorders.initSettingsDefs()
    PropertyBorders.SETTINGS.visible = {
        default = 1,
        values  = {false, true},
        strings = {
            g_i18n:getText("ui_off"),
            g_i18n:getText("ui_on"),
        },
    }
    PropertyBorders.SETTINGS.renderMode = {
        default = 1,
        values  = {"debug", "mesh"},
        strings = {
            g_i18n:getText("propertyBorders_renderMode_debug"),
            g_i18n:getText("propertyBorders_renderMode_mesh"),
        },
    }
    PropertyBorders.SETTINGS.displayScope = {
        default = 1,
        values  = {"owned", "contracted", "all"},
        strings = {
            g_i18n:getText("propertyBorders_showOwnedOnly"),
            g_i18n:getText("propertyBorders_showContracted"),
            g_i18n:getText("propertyBorders_showAll"),
        },
    }
    PropertyBorders.SETTINGS.height = {
        default = 3,
        values  = {0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0},
        strings = {
            "0.05 m", "0.1 m", "0.2 m", "0.3 m", "0.5 m",
            "0.75 m", "1.0 m", "1.5 m", "2.0 m",
        },
    }
    PropertyBorders.SETTINGS.colorPreset = {
        default = 1,
        values  = {
            {0.2, 0.8, 1.0, 0.4},   -- Cyan
            {0.1, 1.0, 0.1, 0.4},   -- Green
            {1.0, 0.2, 0.2, 0.4},   -- Red
            {1.0, 1.0, 0.0, 0.4},   -- Yellow
            {1.0, 0.5, 0.0, 0.4},   -- Orange
            {0.8, 0.2, 1.0, 0.4},   -- Purple
            {1.0, 1.0, 1.0, 0.4},   -- White
        },
        strings = {
            g_i18n:getText("propertyBorders_color_cyan"),
            g_i18n:getText("propertyBorders_color_green"),
            g_i18n:getText("propertyBorders_color_red"),
            g_i18n:getText("propertyBorders_color_yellow"),
            g_i18n:getText("propertyBorders_color_orange"),
            g_i18n:getText("propertyBorders_color_purple"),
            g_i18n:getText("propertyBorders_color_white"),
        },
    }
end

---------------------------------------------------------------------------
-- Settings value helpers
---------------------------------------------------------------------------
function PropertyBorders.getSettingValue(id)
    if id == "visible" then
        return PropertyBorders.settings.visible
    elseif id == "renderMode" then
        return PropertyBorders.settings.renderMode
    elseif id == "displayScope" then
        return PropertyBorders.settings.displayScope
    elseif id == "height" then
        return PropertyBorders.settings.height
    elseif id == "colorPreset" then
        return PropertyBorders.settings.color
    end
end

function PropertyBorders.setSettingValue(id, value)
    if id == "visible" then
        PropertyBorders.settings.visible = value
    elseif id == "renderMode" then
        PropertyBorders.settings.renderMode = value
    elseif id == "displayScope" then
        PropertyBorders.settings.displayScope = value
    elseif id == "height" then
        PropertyBorders.settings.height = value
    elseif id == "colorPreset" then
        PropertyBorders.settings.color = value
    end
end

function PropertyBorders.getStateIndex(id)
    local currentValue = PropertyBorders.getSettingValue(id)
    local def = PropertyBorders.SETTINGS[id]
    if def == nil then return 1 end

    for i, v in ipairs(def.values) do
        if type(v) == "table" and type(currentValue) == "table" then
            -- Color comparison (compare first 3 components)
            if math.abs(v[1] - currentValue[1]) < 0.01 and
               math.abs(v[2] - currentValue[2]) < 0.01 and
               math.abs(v[3] - currentValue[3]) < 0.01 then
                return i
            end
        elseif v == currentValue then
            return i
        elseif type(v) == "number" and type(currentValue) == "number" then
            if math.abs(v - currentValue) < 0.001 then
                return i
            end
        end
    end

    return def.default
end

---------------------------------------------------------------------------
-- Save / Load settings to disk
---------------------------------------------------------------------------
function PropertyBorders.getSettingsFilePath()
    return Utils.getFilename("modSettings/PropertyBorders.xml", getUserProfileAppPath())
end

function PropertyBorders.saveSettings()
    local filePath = PropertyBorders.getSettingsFilePath()
    local key = "propertyBorders"

    local xmlFile = createXMLFile("settings", filePath, key)
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("PropertyBorders: Could not create settings file '%s'", filePath)
        return
    end

    local s = PropertyBorders.settings

    setXMLBool(xmlFile,   key .. ".visible#value",       s.visible)
    setXMLString(xmlFile, key .. ".renderMode#value",     s.renderMode)
    setXMLString(xmlFile, key .. ".displayScope#value",   s.displayScope)
    setXMLFloat(xmlFile,  key .. ".height#value",         s.height)
    setXMLFloat(xmlFile,  key .. ".color#r",              s.color[1])
    setXMLFloat(xmlFile,  key .. ".color#g",              s.color[2])
    setXMLFloat(xmlFile,  key .. ".color#b",              s.color[3])
    setXMLFloat(xmlFile,  key .. ".color#a",              s.color[4])
    setXMLFloat(xmlFile,  key .. ".contractColor#r",      s.contractColor[1])
    setXMLFloat(xmlFile,  key .. ".contractColor#g",      s.contractColor[2])
    setXMLFloat(xmlFile,  key .. ".contractColor#b",      s.contractColor[3])
    setXMLFloat(xmlFile,  key .. ".contractColor#a",      s.contractColor[4])
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function PropertyBorders.loadSettings()
    local filePath = PropertyBorders.getSettingsFilePath()

    if not fileExists(filePath) then
        -- No settings file yet, create one with defaults
        PropertyBorders.saveSettings()
        return
    end

    local xmlFile = loadXMLFile("propertyBorders", filePath)
    if xmlFile == nil or xmlFile == 0 then
        return
    end

    local key = "propertyBorders"
    local s = PropertyBorders.settings

    if hasXMLProperty(xmlFile, key .. ".visible#value") then
        s.visible = getXMLBool(xmlFile, key .. ".visible#value") or false
    end
    if hasXMLProperty(xmlFile, key .. ".renderMode#value") then
        s.renderMode = getXMLString(xmlFile, key .. ".renderMode#value") or "debug"
    end
    if hasXMLProperty(xmlFile, key .. ".displayScope#value") then
        s.displayScope = getXMLString(xmlFile, key .. ".displayScope#value") or "owned"
    end
    if hasXMLProperty(xmlFile, key .. ".height#value") then
        s.height = getXMLFloat(xmlFile, key .. ".height#value") or 0.3
    end
    if hasXMLProperty(xmlFile, key .. ".color#r") then
        s.color[1] = getXMLFloat(xmlFile, key .. ".color#r") or 0.2
        s.color[2] = getXMLFloat(xmlFile, key .. ".color#g") or 0.8
        s.color[3] = getXMLFloat(xmlFile, key .. ".color#b") or 1.0
        s.color[4] = getXMLFloat(xmlFile, key .. ".color#a") or 0.4
    end
    if hasXMLProperty(xmlFile, key .. ".contractColor#r") then
        s.contractColor[1] = getXMLFloat(xmlFile, key .. ".contractColor#r") or 1.0
        s.contractColor[2] = getXMLFloat(xmlFile, key .. ".contractColor#g") or 0.6
        s.contractColor[3] = getXMLFloat(xmlFile, key .. ".contractColor#b") or 0.1
        s.contractColor[4] = getXMLFloat(xmlFile, key .. ".contractColor#a") or 0.5
    end
    delete(xmlFile)
end

---------------------------------------------------------------------------
-- Settings menu injection (into Game Settings -> General Settings)
-- Pattern from FS25_LumberJack by loki79uk
---------------------------------------------------------------------------
PropertyBordersMenuCallbacks = {}
-- The .name property is required so the focus manager treats this as belonging
-- to the same GUI group as the settings page.
PropertyBordersMenuCallbacks.name = ""

function PropertyBordersMenuCallbacks.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local def = PropertyBorders.SETTINGS[id]
    if def == nil then return end

    local value = def.values[state]
    if value ~= nil then
        PropertyBorders.setSettingValue(id, value)
    end

    -- Rebuild borders when any meaningful setting changes
    if id == "visible" or id == "renderMode" or id == "displayScope" or id == "height" or id == "colorPreset" then
        PropertyBorders:rebuildAllBorders()
    end

    -- Save after every change
    PropertyBorders.saveSettings()

    -- Sync in multiplayer
    if g_server ~= nil then
        g_server:broadcastEvent(PropertyBordersSettingsEvent.new(PropertyBorders.settings))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(PropertyBordersSettingsEvent.new(PropertyBorders.settings))
    end
end

local function updateFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

function PropertyBorders.injectMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil then
        Logging.warning("PropertyBorders: Could not find InGameMenu controller")
        return
    end

    local settingsPage = inGameMenu.pageSettings
    if settingsPage == nil then
        Logging.warning("PropertyBorders: Could not find settings page")
        return
    end

    -- Set name so focus manager recognizes our callbacks as part of the settings page
    PropertyBordersMenuCallbacks.name = settingsPage.name

    -- Helper: add a BinaryOption (2-value toggle)
    local function addBinaryMenuOption(id)
        local callback = "onMenuOptionChanged"
        local i18n_title   = "propertyBorders_setting_" .. id
        local i18n_tooltip = "propertyBorders_tooltip_" .. id
        local options = PropertyBorders.SETTINGS[id].strings

        local originalBox = settingsPage.checkWoodHarvesterAutoCutBox
        if originalBox == nil then
            -- Fallback: try to find any binary option box
            for _, elem in ipairs(settingsPage.generalSettingsLayout.elements) do
                if elem.elements ~= nil and #elem.elements > 0 then
                    local firstChild = elem.elements[1]
                    if firstChild ~= nil and firstChild:isa(BinaryOptionElement) then
                        originalBox = elem
                        break
                    end
                end
            end
        end
        if originalBox == nil then
            Logging.warning("PropertyBorders: Could not find binary option to clone")
            return nil
        end

        local menuOptionBox = originalBox:clone(settingsPage.generalSettingsLayout)
        menuOptionBox.id = id .. "box"

        local menuBinaryOption = menuOptionBox.elements[1]
        menuBinaryOption.id = id
        menuBinaryOption.target = PropertyBordersMenuCallbacks
        menuBinaryOption:setCallback("onClickCallback", callback)
        menuBinaryOption:setDisabled(false)

        local toolTip = menuBinaryOption.elements[1]
        if toolTip ~= nil and toolTip.setText ~= nil then
            toolTip:setText(g_i18n:getText(i18n_tooltip))
        end

        local label = menuOptionBox.elements[2]
        if label ~= nil and label.setText ~= nil then
            label:setText(g_i18n:getText(i18n_title))
        end

        menuBinaryOption:setTexts({unpack(options)})
        menuBinaryOption:setState(PropertyBorders.getStateIndex(id))

        PropertyBorders.CONTROLS[id] = menuBinaryOption

        updateFocusIds(menuOptionBox)
        table.insert(settingsPage.controlsList, menuOptionBox)

        return menuOptionBox
    end

    -- Helper: add a MultiTextOption (multi-value selector)
    local function addMultiMenuOption(id)
        local callback = "onMenuOptionChanged"
        local i18n_title   = "propertyBorders_setting_" .. id
        local i18n_tooltip = "propertyBorders_tooltip_" .. id
        local options = PropertyBorders.SETTINGS[id].strings

        local originalBox = settingsPage.multiVolumeVoiceBox
        if originalBox == nil then
            -- Fallback: try to find any multi-text option box
            for _, elem in ipairs(settingsPage.generalSettingsLayout.elements) do
                if elem.elements ~= nil and #elem.elements > 0 then
                    local firstChild = elem.elements[1]
                    if firstChild ~= nil and firstChild:isa(MultiTextOptionElement) then
                        originalBox = elem
                        break
                    end
                end
            end
        end
        if originalBox == nil then
            Logging.warning("PropertyBorders: Could not find multi-text option to clone")
            return nil
        end

        local menuOptionBox = originalBox:clone(settingsPage.generalSettingsLayout)
        menuOptionBox.id = id .. "box"

        local menuMultiOption = menuOptionBox.elements[1]
        menuMultiOption.id = id
        menuMultiOption.target = PropertyBordersMenuCallbacks
        menuMultiOption:setCallback("onClickCallback", callback)
        menuMultiOption:setDisabled(false)

        local toolTip = menuMultiOption.elements[1]
        if toolTip ~= nil and toolTip.setText ~= nil then
            toolTip:setText(g_i18n:getText(i18n_tooltip))
        end

        local label = menuOptionBox.elements[2]
        if label ~= nil and label.setText ~= nil then
            label:setText(g_i18n:getText(i18n_title))
        end

        menuMultiOption:setTexts({unpack(options)})
        menuMultiOption:setState(PropertyBorders.getStateIndex(id))

        PropertyBorders.CONTROLS[id] = menuMultiOption

        updateFocusIds(menuOptionBox)
        table.insert(settingsPage.controlsList, menuOptionBox)

        return menuOptionBox
    end

    -- Add section header
    local sectionTitle = nil
    for _, elem in ipairs(settingsPage.generalSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(settingsPage.generalSettingsLayout)
            break
        end
    end

    if sectionTitle then
        sectionTitle:setText(g_i18n:getText("propertyBorders_settingsTitle"))
    else
        sectionTitle = TextElement.new()
        sectionTitle:applyProfile("fs25_settingsSectionHeader", true)
        sectionTitle:setText(g_i18n:getText("propertyBorders_settingsTitle"))
        sectionTitle.name = "sectionHeader"
        settingsPage.generalSettingsLayout:addElement(sectionTitle)
    end

    sectionTitle.focusId = FocusManager:serveAutoFocusId()
    table.insert(settingsPage.controlsList, sectionTitle)
    PropertyBorders.CONTROLS["sectionHeader"] = sectionTitle

    -- Add setting controls
    for _, id in ipairs(PropertyBorders.menuItems) do
        local def = PropertyBorders.SETTINGS[id]
        if def ~= nil then
            if #def.values == 2 then
                addBinaryMenuOption(id)
            else
                addMultiMenuOption(id)
            end
        end
    end

    settingsPage.generalSettingsLayout:invalidateLayout()

    -- Hook: refresh states every time the settings menu is opened
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
        for _, id in ipairs(PropertyBorders.menuItems) do
            local control = PropertyBorders.CONTROLS[id]
            if control ~= nil then
                control:setState(PropertyBorders.getStateIndex(id))
                control:setDisabled(false)
            end
        end
    end)

    -- Hook: register custom controls with focus manager for keyboard/controller nav
    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        if gui == "ingameMenuSettings" then
            for _, control in pairs(PropertyBorders.CONTROLS) do
                if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                    if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                        Logging.warning("PropertyBorders: Could not register control %s with focus manager",
                            control.id or control.name or tostring(control.focusId))
                    end
                end
            end
            local sp = g_gui.screenControllers[InGameMenu].pageSettings
            if sp ~= nil then
                sp.generalSettingsLayout:invalidateLayout()
            end
        end
    end)

    Logging.info("PropertyBorders: Settings injected into Game Settings menu")
end

---------------------------------------------------------------------------
-- Input action registration (VIP Order Manager pattern)
---------------------------------------------------------------------------
function PropertyBorders.registerInputHook()
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        function(self, controlling)
            local triggerUp = false
            local triggerDown = true
            local triggerAlways = false
            local startActive = true
            local callbackState = nil
            local disableConflictingBindings = true

            local success1, actionEventId1 = g_inputBinding:registerActionEvent(
                InputAction.PROPERTY_BORDERS_TOGGLE, PropertyBorders,
                PropertyBorders.onToggleAction,
                triggerUp, triggerDown, triggerAlways, startActive,
                callbackState, disableConflictingBindings
            )
            if success1 then
                PropertyBorders.toggleEventId = actionEventId1
                g_inputBinding:setActionEventTextPriority(actionEventId1, GS_PRIO_VERY_LOW)
                g_inputBinding:setActionEventTextVisibility(actionEventId1, true)
                Logging.info("PropertyBorders: Toggle action registered (id=%s, controlling=%s)", tostring(actionEventId1), tostring(controlling))
            else
                Logging.warning("PropertyBorders: Failed to register toggle action (controlling=%s)", tostring(controlling))
            end

        end
    )
end

---------------------------------------------------------------------------
-- Lifecycle callbacks
---------------------------------------------------------------------------
function PropertyBorders:loadMap(filename)
    Logging.info("PropertyBorders v1.0.0 by Heavy Metal Gaming - loadMap")

    -- Initialize settings definitions (l10n is available now)
    PropertyBorders.initSettingsDefs()

    -- Load saved settings from disk
    PropertyBorders.loadSettings()

    -- Always initialize mesh renderer so it is ready when switching modes
    local meshOk = BorderRendererMesh.init(PropertyBorders.modDir)
    if not meshOk then
        Logging.warning("PropertyBorders: Mesh renderer init failed, forcing debug mode")
        PropertyBorders.settings.renderMode = "debug"
    end

    -- Register input actions via PlayerInputComponent hook (VIP Order Manager pattern)
    PropertyBorders.registerInputHook()

    -- Subscribe to farmland ownership changes (guard: constant may not exist in all FS25 versions)
    if g_farmlandManager ~= nil and g_messageCenter ~= nil then
        local msgType = MessageType ~= nil and MessageType.FARMLAND_OWNERSHIP_CHANGED or nil
        if msgType ~= nil then
            g_messageCenter:subscribe(msgType, PropertyBorders.onFarmlandOwnershipChanged, self)
        else
            Logging.info("PropertyBorders: MessageType.FARMLAND_OWNERSHIP_CHANGED not available, using polling fallback")
        end
    end

    -- Inject settings into the Game Settings menu
    PropertyBorders.injectMenu()

    -- Hook: send initial state to connecting clients
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        function(mission, connection, user, farm)
            if PropertyBorders.settings ~= nil then
                connection:sendEvent(PropertyBordersSettingsInitialEvent.new(PropertyBorders.settings))
            end
        end
    )

    PropertyBorders.isInitialized = true
    PropertyBorders.needsInitialScan = true   -- defer scan until update() when farmlands are ready
end

function PropertyBorders:deleteMap()
    Logging.info("PropertyBorders: deleteMap - cleaning up")

    -- Save settings
    PropertyBorders.saveSettings()

    -- Clean up mesh renderer
    BorderRendererMesh.destroy()

    -- Clean up notification overlays
    if PropertyBorders.notifBgScale ~= nil then
        PropertyBorders.notifBgScale:delete()
        PropertyBorders.notifBgScale = nil
    end
    if PropertyBorders.notifBgLeft ~= nil then
        PropertyBorders.notifBgLeft:delete()
        PropertyBorders.notifBgLeft = nil
    end
    if PropertyBorders.notifBgRight ~= nil then
        PropertyBorders.notifBgRight:delete()
        PropertyBorders.notifBgRight = nil
    end

    -- Clear caches
    PropertyBorders.borderCache = {}
    PropertyBorders.contractBorderCache = {}
    PropertyBorders.isInitialized = false
    PropertyBorders.inputRegistered = false
    PropertyBorders.toggleEventId = nil

    -- Remove action events
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(PropertyBorders)
    end

    -- Unsubscribe
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
end

function PropertyBorders:update(dt)
    if not PropertyBorders.isInitialized then return end

    -- Deferred initial scan: wait until farmlands are actually loaded
    if PropertyBorders.needsInitialScan then
        if g_farmlandManager ~= nil and g_farmlandManager.localMap ~= nil then
            PropertyBorders.needsInitialScan = false
            Logging.info("PropertyBorders: Farmlands now ready, running deferred initial scan")
            if PropertyBorders.settings.visible then
                PropertyBorders:rebuildAllBorders()
            end
        end
        return  -- don't do anything else until initial scan is done
    end

    if not PropertyBorders.settings.visible then return end

    -- Periodically refresh contract borders
    if PropertyBorders.settings.displayScope == "contracted" or
       PropertyBorders.settings.displayScope == "all" then
        PropertyBorders.contractRefreshTimer = PropertyBorders.contractRefreshTimer + dt
        if PropertyBorders.contractRefreshTimer >= PropertyBorders.CONTRACT_REFRESH_INTERVAL then
            PropertyBorders.contractRefreshTimer = 0
            PropertyBorders:refreshContractBorders()
        end
    end
end

function PropertyBorders:draw()
    if not PropertyBorders.isInitialized then return end

    -- Detect whether the game HUD is hidden (V key or photo mode)
    local hudHidden = g_noHudModeEnabled or (g_currentMission.hud ~= nil and not g_currentMission.hud.isVisible)

    -- ---- HUD-hidden border dimming (mesh mode) ----
    -- When the HUD is hidden, reduce border glow to 15% of normal.
    if PropertyBorders.settings.renderMode == "mesh" and PropertyBorders.settings.visible then
        local wantDimmed = hudHidden
        if wantDimmed ~= PropertyBorders.isBorderDimmed then
            PropertyBorders.isBorderDimmed = wantDimmed
            BorderRendererMesh.setGlowMultiplier(wantDimmed and 0.20 or 1.0)
        end
    end

    -- ---- Custom notification overlay ----
    -- Suppress when HUD is hidden
    if PropertyBorders.notificationText ~= nil and not hudHidden then
        local now = g_time or 0
        local remaining = PropertyBorders.notificationEndTime - now
        if remaining > 0 then
            -- Compute alpha with fade-out at the end
            local alpha = 1.0
            if remaining < PropertyBorders.NOTIFICATION_FADE then
                alpha = remaining / PropertyBorders.NOTIFICATION_FADE
            end
            PropertyBorders.drawNotification(PropertyBorders.notificationText, alpha)
        else
            PropertyBorders.notificationText = nil
        end
    elseif PropertyBorders.notificationText ~= nil and hudHidden then
        -- still tick the timer so it expires even while HUD is hidden
        if (g_time or 0) >= PropertyBorders.notificationEndTime then
            PropertyBorders.notificationText = nil
        end
    end

    -- ---- Debug renderer draws every frame ----
    if not PropertyBorders.settings.visible then return end

    -- Debug renderer draws every frame
    if PropertyBorders.settings.renderMode == "debug" then
        -- When HUD hidden, reduce debug line alpha to 15%
        local debugAlphaMul = hudHidden and 0.20 or 1.0

        -- Draw owned borders
        BorderRendererDebug.draw(PropertyBorders, debugAlphaMul)

        -- Draw contract borders with contract color
        if PropertyBorders.settings.displayScope == "contracted" or
           PropertyBorders.settings.displayScope == "all" then
            local savedColor = PropertyBorders.settings.color
            PropertyBorders.settings.color = PropertyBorders.settings.contractColor

            local savedCache = PropertyBorders.borderCache
            PropertyBorders.borderCache = PropertyBorders.contractBorderCache
            BorderRendererDebug.draw(PropertyBorders, debugAlphaMul)
            PropertyBorders.borderCache = savedCache

            PropertyBorders.settings.color = savedColor
        end
    end
    -- Mesh renderer is persistent, no per-frame draw needed
end

---------------------------------------------------------------------------
-- Notification drawing — HUD-style overlay box (same pattern as game's TopNotification)
---------------------------------------------------------------------------
function PropertyBorders.ensureNotifOverlays()
    if PropertyBorders.notifBgScale ~= nil then
        return true
    end
    if g_overlayManager == nil then
        return false
    end
    -- Use the game's registered HUD overlay slices for a standard look
    PropertyBorders.notifBgScale = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
    PropertyBorders.notifBgLeft  = g_overlayManager:createOverlay("gui.gameInfo_left",   0, 0, 0, 0)
    PropertyBorders.notifBgRight = g_overlayManager:createOverlay("gui.gameInfo_right",  0, 0, 0, 0)
    if PropertyBorders.notifBgScale == nil then
        Logging.warning("PropertyBorders: Failed to create HUD overlay from g_overlayManager")
        return false
    end
    return true
end

function PropertyBorders.drawNotification(text, alpha)
    local fontSize = 0.028
    local posY = 0.96   -- near the top of the screen
    local padY   = 0.010

    -- Near-white slightly gray text color
    local textR, textG, textB = 0.92, 0.92, 0.92

    -- HUD background box with left/right caps
    if PropertyBorders.ensureNotifOverlays() then
        local textWidth = getTextWidth(fontSize, text)
        local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
        a = a * alpha

        local padX   = 0.018
        local capW   = 0.005   -- left/right cap width
        local boxW   = textWidth + padX * 2
        local boxH   = fontSize + padY * 2
        local boxX   = 0.5 - boxW * 0.5
        local boxY   = posY - padY

        -- Left cap
        PropertyBorders.notifBgLeft:setColor(r, g, b, a)
        PropertyBorders.notifBgLeft:setDimension(capW, boxH)
        PropertyBorders.notifBgLeft:setPosition(boxX - capW, boxY)
        PropertyBorders.notifBgLeft:render()
        -- Center stretch
        PropertyBorders.notifBgScale:setColor(r, g, b, a)
        PropertyBorders.notifBgScale:setDimension(boxW, boxH)
        PropertyBorders.notifBgScale:setPosition(boxX, boxY)
        PropertyBorders.notifBgScale:render()
        -- Right cap
        PropertyBorders.notifBgRight:setColor(r, g, b, a)
        PropertyBorders.notifBgRight:setDimension(capW, boxH)
        PropertyBorders.notifBgRight:setPosition(boxX + boxW, boxY)
        PropertyBorders.notifBgRight:render()
    end

    -- Vertically center text inside the box (renderText Y = baseline)
    local textY = posY - padY + (fontSize + padY * 2) * 0.5 - fontSize * 0.4

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(false)
    setTextColor(textR, textG, textB, alpha)
    renderText(0.5, textY, fontSize, text)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

---------------------------------------------------------------------------
-- Input action handlers
---------------------------------------------------------------------------
function PropertyBorders:onToggleAction(actionName, inputValue, callbackState, isAnalog)
    PropertyBorders.settings.visible = not PropertyBorders.settings.visible

    if PropertyBorders.settings.visible then
        PropertyBorders.notificationText    = g_i18n:getText("propertyBorders_enabled")
        PropertyBorders.notificationEndTime = (g_time or 0) + PropertyBorders.NOTIFICATION_DURATION
        PropertyBorders.isBorderDimmed = false  -- force re-evaluation for new clones
        PropertyBorders:rebuildAllBorders()
        -- If HUD is already hidden, immediately dim the freshly-created clones
        local hudHidden = g_noHudModeEnabled or (g_currentMission.hud ~= nil and not g_currentMission.hud.isVisible)
        if hudHidden and PropertyBorders.settings.renderMode == "mesh" then
            PropertyBorders.isBorderDimmed = true
            BorderRendererMesh.setGlowMultiplier(0.20)
        end
    else
        PropertyBorders.notificationText    = g_i18n:getText("propertyBorders_disabled")
        PropertyBorders.notificationEndTime = (g_time or 0) + PropertyBorders.NOTIFICATION_DURATION
        -- Hide mesh borders
        if PropertyBorders.settings.renderMode == "mesh" then
            BorderRendererMesh.setVisible(false)
        end
    end

    -- Save and sync
    PropertyBorders.saveSettings()
    if g_server ~= nil then
        g_server:broadcastEvent(PropertyBordersSettingsEvent.new(PropertyBorders.settings))
    end
end

---------------------------------------------------------------------------
-- Farmland ownership change handler
---------------------------------------------------------------------------
function PropertyBorders:onFarmlandOwnershipChanged(farmlandId, farmId)
    if not PropertyBorders.isInitialized then return end
    if not PropertyBorders.settings.visible then return end

    PropertyBorders:rebuildAllBorders()
end

---------------------------------------------------------------------------
-- Border scanning & cache management
---------------------------------------------------------------------------
function PropertyBorders:rebuildAllBorders()
    if not PropertyBorders.isInitialized then return end

    Logging.info("PropertyBorders: rebuildAllBorders() called, renderMode=%s, visible=%s",
        tostring(PropertyBorders.settings.renderMode), tostring(PropertyBorders.settings.visible))

    -- Clean up existing mesh borders
    if PropertyBorders.settings.renderMode == "mesh" then
        BorderRendererMesh.removeAll()
    end

    -- Clear caches
    PropertyBorders.borderCache = {}
    PropertyBorders.contractBorderCache = {}

    if g_farmlandManager == nil or g_farmlandManager.localMap == nil then
        Logging.info("PropertyBorders: rebuildAllBorders - farmlandManager not ready (mgr=%s, localMap=%s)",
            tostring(g_farmlandManager), tostring(g_farmlandManager ~= nil and g_farmlandManager.localMap or "N/A"))
        return
    end

    -- Apply colorblind adjustments if active
    local color = PropertyBorders.settings.color
    if g_gameSettings ~= nil and g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) then
        -- Use high-contrast colorblind-friendly palette (blue/orange)
        color = {0.0, 0.45, 0.7, color[4]}
    end

    -- Scan owned farmlands
    local myFarmId = g_currentMission:getFarmId()
    local farmlands = g_farmlandManager:getFarmlands()

    -- Initialize mesh renderer if needed
    if PropertyBorders.settings.renderMode == "mesh" and not BorderRendererMesh.materialLoaded then
        local success = BorderRendererMesh.init(PropertyBorders.modDir)
        if not success then
            PropertyBorders.settings.renderMode = "debug"
        end
    end

    local farmlandCount = 0
    local scannedCount = 0
    for _, farmland in pairs(farmlands) do
        farmlandCount = farmlandCount + 1
        local shouldScan = false

        if PropertyBorders.settings.displayScope == "all" then
            shouldScan = true
        elseif farmland.farmId == myFarmId then
            shouldScan = true
        end

        if shouldScan and farmland.id ~= nil then
            local edges = BorderScanner.scanFarmlandEdges(farmland.id)
            if #edges > 0 then
                scannedCount = scannedCount + 1
                local polylines = BorderScanner.chainEdges(edges)
                local simplified = {}
                for _, pl in ipairs(polylines) do
                    simplified[#simplified + 1] = BorderScanner.simplifyPolyline(pl, PropertyBorders.SIMPLIFY_TOLERANCE)
                end
                local worldPoly = BorderScanner.toWorldCoords(simplified, PropertyBorders.settings.height)
                PropertyBorders.borderCache[farmland.id] = worldPoly

                -- Create mesh if in mesh mode
                if PropertyBorders.settings.renderMode == "mesh" then
                    BorderRendererMesh.createForFarmland(farmland.id, worldPoly, color, PropertyBorders.STRIP_WIDTH)
                end
            end
        end
    end

    -- Refresh contract borders
    if PropertyBorders.settings.displayScope == "contracted" or
       PropertyBorders.settings.displayScope == "all" then
        PropertyBorders:refreshContractBorders()
    end

    -- Show/hide mesh renderer
    if PropertyBorders.settings.renderMode == "mesh" then
        BorderRendererMesh.setVisible(PropertyBorders.settings.visible)
    end

    Logging.info("PropertyBorders: rebuildAllBorders done - %d farmlands, %d scanned, myFarmId=%s, displayScope=%s",
        farmlandCount, scannedCount, tostring(myFarmId), tostring(PropertyBorders.settings.displayScope))
end

function PropertyBorders:refreshContractBorders()
    -- Clear previous contract cache
    PropertyBorders.contractBorderCache = {}

    if g_missionManager == nil then return end

    local myFarmId = g_currentMission:getFarmId()
    local contractColor = PropertyBorders.settings.contractColor

    if g_gameSettings ~= nil and g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) then
        contractColor = {0.9, 0.6, 0.0, contractColor[4]}
    end

    for _, mission in pairs(g_missionManager.missions) do
        if mission.status ~= nil and mission.status == AbstractMission.STATUS_RUNNING then
            if mission.farmId == myFarmId and mission.field ~= nil and mission.field.farmland ~= nil then
                local farmlandId = mission.field.farmland.id
                -- Only add if not already in owned cache
                if PropertyBorders.borderCache[farmlandId] == nil then
                    local edges = BorderScanner.scanFarmlandEdges(farmlandId)
                    if #edges > 0 then
                        local polylines = BorderScanner.chainEdges(edges)
                        local simplified = {}
                        for _, pl in ipairs(polylines) do
                            simplified[#simplified + 1] = BorderScanner.simplifyPolyline(pl, PropertyBorders.SIMPLIFY_TOLERANCE)
                        end
                        local worldPoly = BorderScanner.toWorldCoords(simplified, PropertyBorders.settings.height)
                        PropertyBorders.contractBorderCache[farmlandId] = worldPoly

                        if PropertyBorders.settings.renderMode == "mesh" then
                            BorderRendererMesh.createForFarmland(farmlandId, worldPoly, contractColor, PropertyBorders.STRIP_WIDTH)
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Register as mod event listener
---------------------------------------------------------------------------
addModEventListener(PropertyBorders)

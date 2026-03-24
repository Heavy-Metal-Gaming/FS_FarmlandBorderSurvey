---
--- PropertyBordersSettingsInitialEvent.lua
--- Network event sent to newly connecting clients with the current border settings.
---

PropertyBordersSettingsInitialEvent = {}
local PropertyBordersSettingsInitialEvent_mt = Class(PropertyBordersSettingsInitialEvent, Event)

InitEventClass(PropertyBordersSettingsInitialEvent, "PropertyBordersSettingsInitialEvent")

function PropertyBordersSettingsInitialEvent.emptyNew()
    local self = Event.new(PropertyBordersSettingsInitialEvent_mt)
    return self
end

function PropertyBordersSettingsInitialEvent.new(settings)
    local self = PropertyBordersSettingsInitialEvent.emptyNew()
    self.colorR = settings.color[1]
    self.colorG = settings.color[2]
    self.colorB = settings.color[3]
    self.colorA = settings.color[4]
    self.height = settings.height
    self.renderMode = settings.renderMode
    self.visible = settings.visible
    return self
end

function PropertyBordersSettingsInitialEvent:readStream(streamId, connection)
    self.colorR = streamReadFloat32(streamId)
    self.colorG = streamReadFloat32(streamId)
    self.colorB = streamReadFloat32(streamId)
    self.colorA = streamReadFloat32(streamId)
    self.height = streamReadFloat32(streamId)
    self.renderMode = streamReadString(streamId)
    self.visible = streamReadBool(streamId)

    self:run(connection)
end

function PropertyBordersSettingsInitialEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.colorR)
    streamWriteFloat32(streamId, self.colorG)
    streamWriteFloat32(streamId, self.colorB)
    streamWriteFloat32(streamId, self.colorA)
    streamWriteFloat32(streamId, self.height)
    streamWriteString(streamId, self.renderMode)
    streamWriteBool(streamId, self.visible)
end

function PropertyBordersSettingsInitialEvent:run(connection)
    -- Apply received initial settings on the client
    if PropertyBorders ~= nil then
        local settings = PropertyBorders.settings
        settings.color = {self.colorR, self.colorG, self.colorB, self.colorA}
        settings.height = self.height
        settings.renderMode = self.renderMode
        settings.visible = self.visible

        -- Rebuild borders with synced settings
        PropertyBorders:rebuildAllBorders()
    end
end

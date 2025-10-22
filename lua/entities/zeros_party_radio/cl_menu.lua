

local info01 = [[
Note: Only direct audio file URLs are supported.
Accepted formats: MP3, OGG, WAV, M4A, FLAC

Examples of valid URLs:
• https://example.com/music.mp3
• https://cdn.site.com/audio/song.ogg

YouTube, Spotify, and other streaming service URLs will NOT work.
The URL must point directly to an audio file.
]]


local info02 = [[
Performance Tips:
• Disable effects if you experience lag
• Increase update rate for better performance
• Effects auto-disable at long distances
]]


-- cl_menu.lua - Admin Interface with improved security
local PANEL = {}

function PANEL:Init()
    self:SetSize(600, 500)
    self:SetTitle("Party Radio Control")
    self:Center()
    self:MakePopup()
    self:SetDraggable(true)
    self:ShowCloseButton(true)

    self.Radio = nil
    self.Playlist = {}

    -- Create tabs
    self.TabPanel = vgui.Create("DPropertySheet", self)
    self.TabPanel:Dock(FILL)

    -- Playlist tab
    self.PlaylistPanel = vgui.Create("DPanel", self.TabPanel)
    self.PlaylistPanel.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40))
    end

    self:CreatePlaylistControls()

    -- Add URL tab
    self.AddURLPanel = vgui.Create("DPanel", self.TabPanel)
    self.AddURLPanel.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40))
    end

    self:CreateAddURLControls()

    -- Settings tab
    self.SettingsPanel = vgui.Create("DPanel", self.TabPanel)
    self.SettingsPanel.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40))
    end

    self:CreateSettingsControls()

    -- Add tabs
    self.TabPanel:AddSheet("Playlist", self.PlaylistPanel, "icon16/music.png")
    self.TabPanel:AddSheet("Add Music", self.AddURLPanel, "icon16/add.png")
    self.TabPanel:AddSheet("Settings", self.SettingsPanel, "icon16/cog.png")
end

function PANEL:CreatePlaylistControls()
    -- Control buttons
    local controlPanel = vgui.Create("DPanel", self.PlaylistPanel)
    controlPanel:SetTall(40)
    controlPanel:Dock(TOP)
    controlPanel:DockMargin(5, 5, 5, 5)
    controlPanel.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(50, 50, 50))
    end

    -- Play/Stop button
    self.PlayButton = vgui.Create("DButton", controlPanel)
    self.PlayButton:SetText("Play")
    self.PlayButton:SetWide(80)
    self.PlayButton:Dock(LEFT)
    self.PlayButton:DockMargin(5, 5, 5, 5)
    self.PlayButton.DoClick = function()
        if IsValid(self.Radio) then
            if self.PlayButton:GetText() == "Play" then
                net.Start("PartyRadio_PlayNext")
                net.WriteEntity(self.Radio)
                net.SendToServer()
                self.PlayButton:SetText("Stop")
            else
                net.Start("PartyRadio_Stop")
                net.WriteEntity(self.Radio)
                net.SendToServer()
                self.PlayButton:SetText("Play")
            end
        end
    end

    -- Skip button
    local skipButton = vgui.Create("DButton", controlPanel)
    skipButton:SetText("Skip")
    skipButton:SetWide(80)
    skipButton:Dock(LEFT)
    skipButton:DockMargin(0, 5, 5, 5)
    skipButton.DoClick = function()
        if IsValid(self.Radio) then
            net.Start("PartyRadio_PlayNext")
            net.WriteEntity(self.Radio)
            net.SendToServer()
        end
    end

    -- Playlist view
    self.PlaylistView = vgui.Create("DListView", self.PlaylistPanel)
    self.PlaylistView:Dock(FILL)
    self.PlaylistView:DockMargin(5, 5, 5, 5)
    self.PlaylistView:SetMultiSelect(false)
    self.PlaylistView:AddColumn("Name")
    self.PlaylistView:AddColumn("Artist")
    self.PlaylistView:AddColumn("Genre")

    -- Double click to play
    self.PlaylistView.DoDoubleClick = function(lst, index, pnl)
        if IsValid(self.Radio) and index then
            net.Start("PartyRadio_PlaySpecific")
            net.WriteEntity(self.Radio)
            net.WriteUInt(index, 16)
            net.SendToServer()
            self.PlayButton:SetText("Stop")
        end
    end

    -- Right-click menu
    self.PlaylistView.OnRowRightClick = function(lst, index, pnl)
        local menu = DermaMenu()

        menu:AddOption("Play", function()
            if IsValid(self.Radio) and index then
                net.Start("PartyRadio_PlaySpecific")
                net.WriteEntity(self.Radio)
                net.WriteUInt(index, 16)
                net.SendToServer()
                self.PlayButton:SetText("Stop")
            end
        end):SetIcon("icon16/control_play.png")

        menu:AddSpacer()

        menu:AddOption("Remove", function()
            if IsValid(self.Radio) and index then
                net.Start("PartyRadio_RemoveSong")
                net.WriteEntity(self.Radio)
                net.WriteUInt(index, 16)
                net.SendToServer()
            end
        end):SetIcon("icon16/delete.png")

        menu:Open()
    end
end

function PANEL:CreateAddURLControls()
    local container = vgui.Create("DScrollPanel", self.AddURLPanel)
    container:Dock(FILL)
    container:DockMargin(10, 10, 10, 10)

    -- Name input
    local nameLabel = vgui.Create("DLabel", container)
    nameLabel:SetText("Song Name:")
    nameLabel:SetTextColor(Color(255, 255, 255))
    nameLabel:Dock(TOP)
    nameLabel:DockMargin(0, 0, 0, 5)

    self.NameEntry = vgui.Create("DTextEntry", container)
    self.NameEntry:Dock(TOP)
    self.NameEntry:DockMargin(0, 0, 0, 10)
    self.NameEntry:SetPlaceholderText("Enter song name...")

    -- Artist input
    local artistLabel = vgui.Create("DLabel", container)
    artistLabel:SetText("Artist:")
    artistLabel:SetTextColor(Color(255, 255, 255))
    artistLabel:Dock(TOP)
    artistLabel:DockMargin(0, 0, 0, 5)

    self.ArtistEntry = vgui.Create("DTextEntry", container)
    self.ArtistEntry:Dock(TOP)
    self.ArtistEntry:DockMargin(0, 0, 0, 10)
    self.ArtistEntry:SetPlaceholderText("Enter artist name...")

    -- Genre input
    local genreLabel = vgui.Create("DLabel", container)
    genreLabel:SetText("Genre:")
    genreLabel:SetTextColor(Color(255, 255, 255))
    genreLabel:Dock(TOP)
    genreLabel:DockMargin(0, 0, 0, 5)

    self.GenreEntry = vgui.Create("DTextEntry", container)
    self.GenreEntry:Dock(TOP)
    self.GenreEntry:DockMargin(0, 0, 0, 10)
    self.GenreEntry:SetPlaceholderText("Enter genre...")

    -- URL input
    local urlLabel = vgui.Create("DLabel", container)
    urlLabel:SetText("Audio URL (MP3/OGG):")
    urlLabel:SetTextColor(Color(255, 255, 255))
    urlLabel:Dock(TOP)
    urlLabel:DockMargin(0, 0, 0, 5)

    self.URLEntry = vgui.Create("DTextEntry", container)
    self.URLEntry:Dock(TOP)
    self.URLEntry:DockMargin(0, 0, 0, 10)
    self.URLEntry:SetPlaceholderText("https://example.com/song.mp3")

    -- Add button
    local addButton = vgui.Create("DButton", container)
    addButton:SetText("Add to Playlist")
    addButton:SetTall(30)
    addButton:Dock(TOP)
    addButton:DockMargin(0, 10, 0, 0)
    addButton.DoClick = function()
        self:AddSongToPlaylist()
    end

    -- Help text
    local helpText = vgui.Create("DLabel", container)
    helpText:SetText(info01)
    helpText:SetTextColor(Color(200, 200, 200))
    helpText:SetWrap(true)
    helpText:SetAutoStretchVertical(true)
    helpText:Dock(TOP)
    helpText:DockMargin(0, 20, 0, 0)
end

function PANEL:AddSongToPlaylist()
    local name = string.Trim(self.NameEntry:GetValue())
    local artist = string.Trim(self.ArtistEntry:GetValue())
    local genre = string.Trim(self.GenreEntry:GetValue())
    local url = string.Trim(self.URLEntry:GetValue())

    -- Validation
    if name == "" then
        Derma_Message("Please enter a song name!", "Error", "OK")
        return
    end

    if url == "" then
        Derma_Message("Please enter a URL!", "Error", "OK")
        return
    end

    -- Basic URL validation
    if not string.match(url, "^https?://") then
        Derma_Message("URL must start with http:// or https://", "Error", "OK")
        return
    end

    -- Check for audio file extension
    local validExtensions = {".mp3", ".ogg", ".wav", ".m4a", ".flac"}
    local hasValidExtension = false
    for _, ext in ipairs(validExtensions) do
        if string.find(string.lower(url), ext, 1, true) then
            hasValidExtension = true
            break
        end
    end

    if not hasValidExtension then
        local confirm = Derma_Query(
            "The URL doesn't appear to point to a common audio format.\nAre you sure you want to add it?",
            "Warning",
            "Yes", function()
                self:SendAddSongRequest(name, artist, genre, url)
            end,
            "No"
        )
        return
    end

    self:SendAddSongRequest(name, artist, genre, url)
end

function PANEL:SendAddSongRequest(name, artist, genre, url)
    if not IsValid(self.Radio) then return end

    net.Start("PartyRadio_AddURL")
    net.WriteEntity(self.Radio)
    net.WriteTable({
        name = name,
        artist = artist or "Unknown",
        genre = genre or "Custom",
        url = url
    })
    net.SendToServer()

    -- Clear fields
    self.NameEntry:SetValue("")
    self.ArtistEntry:SetValue("")
    self.GenreEntry:SetValue("")
    self.URLEntry:SetValue("")

    notification.AddLegacy("Song added to playlist!", NOTIFY_GENERIC, 3)
    surface.PlaySound("buttons/button14.wav")
end

function PANEL:CreateSettingsControls()
    local container = vgui.Create("DScrollPanel", self.SettingsPanel)
    container:Dock(FILL)
    container:DockMargin(10, 10, 10, 10)

    -- Volume slider
    local volumeLabel = vgui.Create("DLabel", container)
    volumeLabel:SetText("Volume:")
    volumeLabel:SetTextColor(Color(255, 255, 255))
    volumeLabel:Dock(TOP)
    volumeLabel:DockMargin(0, 0, 0, 5)

    self.VolumeSlider = vgui.Create("DNumSlider", container)
    self.VolumeSlider:Dock(TOP)
    self.VolumeSlider:DockMargin(0, 0, 0, 10)
    self.VolumeSlider:SetMin(0)
    self.VolumeSlider:SetMax(1)
    self.VolumeSlider:SetDecimals(2)
    self.VolumeSlider:SetValue(0.5)
    self.VolumeSlider.OnValueChanged = function(_, value)
        if IsValid(self.Radio) then
            net.Start("PartyRadio_SetVolume")
            net.WriteEntity(self.Radio)
            net.WriteFloat(value)
            net.SendToServer()
        end
    end

    -- Effects toggles
    local effectsLabel = vgui.Create("DLabel", container)
    effectsLabel:SetText("Visual Effects (Client-side):")
    effectsLabel:SetTextColor(Color(255, 255, 255))
    effectsLabel:Dock(TOP)
    effectsLabel:DockMargin(0, 20, 0, 5)

    local particlesCheck = vgui.Create("DCheckBoxLabel", container)
    particlesCheck:SetText("Enable Particles")
    particlesCheck:SetTextColor(Color(255, 255, 255))
    particlesCheck:SetValue(1)
    particlesCheck:Dock(TOP)
    particlesCheck:DockMargin(20, 5, 0, 5)
    particlesCheck.OnChange = function(_, val)
        if IsValid(self.Radio) then
            self.Radio.Config.Effects.EnableParticles = val
        end
    end

    local lightingCheck = vgui.Create("DCheckBoxLabel", container)
    lightingCheck:SetText("Enable Dynamic Lighting")
    lightingCheck:SetTextColor(Color(255, 255, 255))
    lightingCheck:SetValue(1)
    lightingCheck:Dock(TOP)
    lightingCheck:DockMargin(20, 0, 0, 5)
    lightingCheck.OnChange = function(_, val)
        if IsValid(self.Radio) then
            self.Radio.Config.Effects.EnableLighting = val
        end
    end

    local shakeCheck = vgui.Create("DCheckBoxLabel", container)
    shakeCheck:SetText("Enable Screen Shake")
    shakeCheck:SetTextColor(Color(255, 255, 255))
    shakeCheck:SetValue(1)
    shakeCheck:Dock(TOP)
    shakeCheck:DockMargin(20, 0, 0, 5)
    shakeCheck.OnChange = function(_, val)
        if IsValid(self.Radio) then
            self.Radio.Config.Effects.EnableScreenShake = val
        end
    end

    -- Performance settings
    local perfLabel = vgui.Create("DLabel", container)
    perfLabel:SetText("Performance Settings:")
    perfLabel:SetTextColor(Color(255, 255, 255))
    perfLabel:Dock(TOP)
    perfLabel:DockMargin(0, 20, 0, 5)

    local updateRateSlider = vgui.Create("DNumSlider", container)
    updateRateSlider:SetText("Update Rate")
    updateRateSlider:Dock(TOP)
    updateRateSlider:DockMargin(0, 5, 0, 5)
    updateRateSlider:SetMin(0.01)
    updateRateSlider:SetMax(0.1)
    updateRateSlider:SetDecimals(3)
    updateRateSlider:SetValue(0.03)
    updateRateSlider.OnValueChanged = function(_, value)
        if IsValid(self.Radio) then
            self.Radio.Config.Performance.UpdateRate = value
        end
    end

    -- Info
    local infoLabel = vgui.Create("DLabel", container)
    infoLabel:SetText(info02)
    infoLabel:SetTextColor(Color(180, 180, 180))
    infoLabel:SetWrap(true)
    infoLabel:SetAutoStretchVertical(true)
    infoLabel:Dock(TOP)
    infoLabel:DockMargin(0, 20, 0, 0)
end

function PANEL:SetRadio(ent, playlist, isPlaying, volume)
    if not IsValid(ent) then
        self:Remove()
        return
    end

    self.Radio = ent
    self.Playlist = playlist or {}

    -- Update playlist view
    self.PlaylistView:Clear()
    for i, song in ipairs(self.Playlist) do
        if istable(song) then
            self.PlaylistView:AddLine(
                song.name or "Unknown",
                song.artist or "Unknown",
                song.genre or "Unknown"
            )
        end
    end

    -- Update play button
    if isPlaying then
        self.PlayButton:SetText("Stop")
    else
        self.PlayButton:SetText("Play")
    end

    -- Update volume
    if self.VolumeSlider and volume then
        self.VolumeSlider:SetValue(volume)
    end
end

function PANEL:OnRemove()
    -- Cleanup
end

vgui.Register("PartyRadioMenu", PANEL, "DFrame")

-- Global variable for easy access
local PartyRadioMenuPanel = nil

-- Network receiver for opening menu
net.Receive("PartyRadio_OpenMenu", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local playlist = net.ReadTable()
    local isPlaying = net.ReadBool()
    local volume = net.ReadFloat()

    -- Close existing menu
    if IsValid(PartyRadioMenuPanel) then
        PartyRadioMenuPanel:Remove()
    end

    -- Create new menu
    PartyRadioMenuPanel = vgui.Create("PartyRadioMenu")
    PartyRadioMenuPanel:SetRadio(ent, playlist, isPlaying, volume)
end)

-- Update playlist when it changes
net.Receive("PartyRadio_UpdatePlaylist", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local playlist = net.ReadTable()

    if IsValid(PartyRadioMenuPanel) and PartyRadioMenuPanel.Radio == ent then
        PartyRadioMenuPanel.Playlist = playlist or {}

        PartyRadioMenuPanel.PlaylistView:Clear()
        for i, song in ipairs(PartyRadioMenuPanel.Playlist) do
            if istable(song) then
                PartyRadioMenuPanel.PlaylistView:AddLine(
                    song.name or "Unknown",
                    song.artist or "Unknown",
                    song.genre or "Unknown"
                )
            end
        end
    end
end)
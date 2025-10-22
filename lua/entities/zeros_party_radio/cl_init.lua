include("shared.lua")
include("cl_menu.lua")

-- ============================================
-- MATERIAL DEFINITIONS
-- ============================================
-- 2D Sprites for visual effects
local sprite_catch_glow = Material("zerochain/zqs/zqs_target_indicator_glow")
local zqs_crosshair03_glow = Material("zerochain/zqs/zqs_crosshair03_glow.png", "smooth")
local radial_shadow = Material("zerochain/zerolib/ui/radial_shadow.png")

-- Shader Materials for model rendering
local shader_clouds = Material("zerochain/zqs/zqs_ball_highlighter")
local emptool_glow = Material("models/alyx/emptool_glow")
local mat_ring_wave_additive = Material("particle/particle_ring_wave_additive")
local laser = Material("trails/laser")
local sprite_flare = Material("zerochain/zerolib/particle/zlib_flare01")

-- ============================================
-- INITIALIZATION
-- ============================================

--[[
    Initialize entity properties and configurations
    Sets up all the data structures needed for audio analysis and visual effects
]]
function ENT:Initialize()
    -- ===== AUDIO ANALYSIS DATA =====
    self.FFTData = {}           -- Current raw FFT data from the audio channel
    self.FFTSmooth = {}         -- Smoothed FFT data (reduces jitter in visuals)
    self.FFTNormalized = {}     -- Normalized FFT data (0-1 range)

    -- Beat detection data structures
    self.FluxHistory = {Kick = {}, Snare = {}, HiHat = {}, Clap = {}} -- Per-band flux histories
    self.FluxHistorySize = 100  -- Longer history for better adaptation
    self.BeatHistory = {}       -- Timestamps of recently detected beats
    self.LastBeatTimes = {
        Kick = 0,
        Snare = 0,
        HiHat = 0,
        Clap = 0
    }

    -- Adaptive threshold data (not used directly, but kept for compatibility)
    self.AdaptiveThresholds = {
        Kick = 1.5,
        Snare = 1.5,
        HiHat = 1.9,
        Clap = 1.5
    }

    -- Energy history for normalization
    self.EnergyHistory = {}
    self.MaxEnergyHistory = 100
    self.CurrentMaxEnergy = 0.01

    -- ===== PLAYBACK STATE =====
    self.SoundChannel = nil
    self.CurrentSong = nil
    self.Volume = 0.5
    self.IsPlaying = false
    self.CalibrationEndTime = 0  -- Time when calibration ends

    -- ===== VISUAL EFFECT PROPERTIES =====
    self.VisualIntensity = 0
    self.BassIntensity = 0
    self.TrebleIntensity = 0
    self.CurrentColor = Color(100, 100, 255)
    self.TargetColor = Color(100, 100, 255)
    self.BeatScale = 1
    self.ModelScale = 2
    self.LODLevel = 0

    -- ===== FFT VISUALIZATION VARIABLES =====
    self.fft_rot = 0
    self.fft_scale = 1
    self.fft_smooth = 0
    self.fft_ring_count = 5
    self.fft_sphere_count = 3
    self.fft_col01 = Color(255, 255, 255)
    self.fft_col02 = Color(255, 255, 255)
    self.fft_col03 = Color(255, 255, 255)
    self.fft_tempo_avg = 1
    self.fft_data = {}

    -- ===== HOLOGRAM AND ANIMATION =====
    self.EpicShaderTime = 0
    self.HoloModelChange = 0
    self.HoloLastOption = false
    self.FlipRotationDir = false
    self.rot_speed_smooth = 0
    self.rot_speed_target = 0
    self.next_rot_target_check = 0
    self.AnimCycle = 0

    -- ===== INITIALIZE DATA ARRAYS =====
    for i = 1, self.Config.FFT.Bands do
        self.FFTSmooth[i] = 0
        self.FFTNormalized[i] = 0
    end

    self.PrevFFTData = {}
    self.PrevFFTSmooth = {}
    for i = 1, self.Config.FFT.Bands do
        self.PrevFFTData[i] = 0
        self.PrevFFTSmooth[i] = 0
    end

    -- Initialize frequency band mappings
    self:InitializeFrequencyBands()
end

--[[
    Initialize frequency band mappings for more accurate beat detection
    Maps FFT bins to actual frequency ranges based on sample rate
]]
function ENT:InitializeFrequencyBands()
    self.FrequencyBands = self.Config.Frequencies  -- Use config ranges for grouped bands, no raw bin calcs
end

--[[
    Clean up resources when entity is removed
    Stops music and removes timers to prevent memory leaks
]]
function ENT:OnRemove()
    self:StopMusic()
    timer.Remove("PartyRadio_NextSong_" .. self:EntIndex())
end

-- ============================================
-- AUDIO PLAYBACK
-- ============================================

--[[
    Stop music playback and clean up audio resources
]]
function ENT:StopMusic()
    if IsValid(self.SoundChannel) then
        self.SoundChannel:Stop()
        self.SoundChannel = nil
    end
    self.IsPlaying = false
    timer.Remove("PartyRadio_NextSong_" .. self:EntIndex())
end

--[[
    Play a song from a URL
    @param url: Direct URL to an audio file (mp3, ogg, etc.)
]]
function ENT:PlaySound(url)
    -- Validate URL
    if not url or type(url) ~= "string" then return end

    -- Stop any currently playing music
    self:StopMusic()

    -- Reset audio analysis data for new song
    self.EnergyHistory = {}
    self.CurrentMaxEnergy = 0.01
    self.FluxHistory = {Kick = {}, Snare = {}, HiHat = {}, Clap = {}}
    self.BeatHistory = {}
    self.CalibrationEndTime = CurTime() + 5  -- 5-second calibration period

    -- Start playing the new song
    sound.PlayURL(url, "3d noblock", function(channel, errID, errName)
        if not IsValid(channel) then
            print("[Party Radio] Failed to play URL:", errName or "Unknown error", tostring(errID))
            return
        end

        if not IsValid(self) then
            channel:Stop()
            return
        end

        self.SoundChannel = channel
        self.IsPlaying = true

        channel:SetPos(self:GetPos())
        channel:Set3DEnabled(true)
        channel:Set3DFadeDistance(1200, 2500)
        channel:SetVolume(self.Volume)
        channel:Play()

        local length = channel:GetLength()
        if length > 0 then
            timer.Create("PartyRadio_NextSong_" .. self:EntIndex(), length, 1, function()
                if IsValid(self) then
                    net.Start("PartyRadio_PlayNext")
                    net.WriteEntity(self)
                    net.SendToServer()
                end
            end)
        end
    end)
end

--[[
    Check if radio is currently playing music
    @return boolean: true if playing, false otherwise
]]
function ENT:IsRadioPlaying()
    return IsValid(self.SoundChannel) and self.SoundChannel:GetState() == GMOD_CHANNEL_PLAYING
end

-- ============================================
-- AUDIO ANALYSIS
-- ============================================

--[[
    Main FFT analysis function
    Processes audio data to extract frequency information and detect beats
]]
function ENT:AnalyzeFFT()
    -- Only analyze if music is playing
    if not self:IsRadioPlaying() then return end

    -- Get FFT data from audio channel
    local fftTable = {}
    local success = pcall(function()
        self.SoundChannel:FFT(fftTable, self.Config.FFT.Size)
    end)

    if not success or #fftTable == 0 then return end

    -- Save previous frame data
    if self.FFTData and #self.FFTData > 0 then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = self.FFTData[i] or 0
        end
    end

    if not self.PrevFFTData then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = 0
        end
    end

    -- Process new FFT data
    self.FFTData = {}
    local bandSize = math.max(1, math.floor(#fftTable / self.Config.FFT.Bands))
    local maxBandAvg = 0
    local tempAvgs = {}

    for i = 1, self.Config.FFT.Bands do
        local sum = 0
        local count = 0
        local startIdx = math.floor((i - 1) * bandSize) + 1
        local endIdx = math.min(#fftTable, math.floor(i * bandSize))

        for j = startIdx, endIdx do
            if fftTable[j] and type(fftTable[j]) == "number" then
                sum = sum + fftTable[j]
                count = count + 1
            end
        end

        local avg = count > 0 and (sum / count) or 0
        tempAvgs[i] = avg
        maxBandAvg = math.max(maxBandAvg, avg)
    end

    -- Adaptive normalization
    table.insert(self.EnergyHistory, maxBandAvg)
    if #self.EnergyHistory > self.MaxEnergyHistory then
        table.remove(self.EnergyHistory, 1)
    end

    local maxEnergy = 0
    for _, energy in ipairs(self.EnergyHistory) do
        maxEnergy = math.max(maxEnergy, energy)
    end

    self.CurrentMaxEnergy = Lerp(0.05, self.CurrentMaxEnergy or 0.01, maxEnergy)
    local normFactor = (self.CurrentMaxEnergy and self.CurrentMaxEnergy > 0.001) and (4 / self.CurrentMaxEnergy) or 1

    for i = 1, self.Config.FFT.Bands do
        local normAvg = math.Clamp((tempAvgs[i] or 0) * normFactor, 0, 1)
        local smoothing = self.Config.FFT.Smoothing or 0.2
        self.FFTSmooth[i] = Lerp(smoothing, normAvg, self.FFTSmooth[i] or 0)
        self.FFTData[i] = self.FFTSmooth[i]
        self.FFTNormalized[i] = math.min(1, self.FFTSmooth[i])
    end

    -- Calculate spectral flux
    local flux = self:CalculateSpectralFlux()
    self.CurrentFlux = flux

    -- Update intensities
    self.BassIntensity = self:GetFrequencyIntensity("Bass")
    self.TrebleIntensity = self:GetFrequencyIntensity("High")
    self.VisualIntensity = (self.BassIntensity + self.TrebleIntensity) / 2

    -- Visualization helpers
    self.fft_data = self.FFTData
    self.fft_smooth = self.VisualIntensity
    self.fft_scale = 1 + self.VisualIntensity * 2
    self.fft_rot = CurTime() * 30
    self.fft_ring_count = math.floor(self.VisualIntensity * 10) + 1
    self.fft_sphere_count = math.floor(self.VisualIntensity * 5) + 1
    self.fft_col01 = self.CurrentColor
    self.fft_col02 = HSVToColor((CurTime() * 50) % 360, 1, 1)
    self.fft_col03 = HSVToColor((CurTime() * 70) % 360, 1, 1)

    -- Tempo history
    if #self.BeatHistory > 1 then
        local intervals = 0
        for k = 2, #self.BeatHistory do
            intervals = intervals + (self.BeatHistory[k] - self.BeatHistory[k - 1])
        end
        self.fft_tempo_avg = intervals / (#self.BeatHistory - 1)
    else
        self.fft_tempo_avg = 1
    end

    -- Skip beat detection and visuals during calibration
    if CurTime() < self.CalibrationEndTime then return end

    -- Trigger updates after calibration
    self:OnBassUpdate(self.BassIntensity)
    self:OnTrebleUpdate(self.TrebleIntensity)
    self:OnVolumeUpdate(self.VisualIntensity)
    self:DetectBeatsAdvanced()
    self:UpdateVisualColor()
end

--[[
    Calculate spectral flux for onset detection
    Measures the positive change in frequency content between frames
    @return number: Spectral flux value
]]
function ENT:CalculateSpectralFlux()
    -- Initialize previous data if needed
    if not self.PrevFFTData then
        self.PrevFFTData = {}
        for i = 1, self.Config.FFT.Bands do
            self.PrevFFTData[i] = 0
        end
    end

    -- Ensure we have valid FFT data
    if not self.FFTData or #self.FFTData == 0 then
		self.CurrentFlux = 0
        return 0
    end

    -- Calculate weighted spectral flux
    local flux = 0
    for i = 1, math.min(self.Config.FFT.Bands, #self.FFTData) do
        local curr = self.FFTData[i] or 0
        local prev = self.PrevFFTData[i] or 0
        local diff = curr - prev

        -- Only count positive changes (onsets)
        if diff > 0 then
            -- Weight lower frequencies more (they're usually more important for beat detection)
            local weight = 1 + (1 - (i / self.Config.FFT.Bands)) * 0.5
            flux = flux + (diff * weight)
        end
    end

	self.CurrentFlux = flux -- Store current flux for debug display

    return flux
end

--[[
    Get average intensity for a specific frequency range
    @param range: String key from FrequencyBands table
    @return number: Average intensity (0-1)
]]
function ENT:GetFrequencyIntensity(range)
    local band = self.FrequencyBands[range]
    if not band or not self.FFTNormalized then return 0 end

    local sum = 0
    local count = 0

    -- Clamp indices to valid range
    local startIdx = math.max(1, band[1])
    local endIdx = math.min(band[2], #self.FFTNormalized)

    -- Calculate average intensity for this frequency range
    for i = startIdx, endIdx do
        if self.FFTNormalized[i] and type(self.FFTNormalized[i]) == "number" then
            sum = sum + self.FFTNormalized[i]
            count = count + 1
        end
    end

    return count > 0 and (sum / count) or 0
end

-- ============================================
-- ADVANCED BEAT DETECTION
-- ============================================

--[[
    Advanced beat detection using multiple detection methods
    Combines spectral flux, energy peaks, and frequency-specific analysis
]]
function ENT:DetectBeatsAdvanced()
    -- ===== EXISTING BEAT DETECTION =====

    -- KICK DRUM DETECTION
    local kickDetected, kickIntensity = self:DetectFrequencyBeat(
        "SubBass",
        "Kick",
        1.0,
        0.1
    )
    if kickDetected then
        self:OnBeatDetected(kickIntensity, "Kick")
    end

    -- SNARE DRUM DETECTION
    local snareDetected, snareIntensity = self:DetectFrequencyBeat(
        "Mid",
        "Snare",
        1.0,
        0.1
    )
    if snareDetected then
        self:OnBeatDetected(snareIntensity, "Snare")
    end

    -- HI-HAT DETECTION
    local hihatDetected, hihatIntensity = self:DetectFrequencyBeat(
        "High",
        "HiHat",
        1.0,
        0.1
    )
    if hihatDetected then
        self:OnBeatDetected(hihatIntensity, "HiHat")
    end

    -- CLAP/PERCUSSION DETECTION
    local clapDetected, clapIntensity = self:DetectFrequencyBeat(
        "HighMid",
        "Clap",
        1.0,
        0.1
    )
    if clapDetected then
        self:OnBeatDetected(clapIntensity, "Clap")
    end

    -- ===== NEW ADVANCED DETECTION =====

    -- VOCAL ONSET DETECTION
    local vocalDetected, vocalIntensity = self:DetectVocalOnset()
    if vocalDetected then
        self:OnVocalDetected(vocalIntensity)
        -- print("Vocal Onset Detected:", vocalIntensity)
    end

    -- BASSLINE GROOVE DETECTION
    local grooveDetected, grooveConfidence, grooveType = self:DetectBasslineGroove()
    if grooveDetected then
        self:OnBasslineGrooveDetected(grooveConfidence, grooveType)
        -- print("Bassline Groove:", grooveType, "Confidence:", grooveConfidence)
    end

    -- BUILD-UP/DROP DETECTION
    local transitionState, transitionIntensity = self:DetectEnergyTransition()
    if transitionState ~= "steady" then
        self:OnEnergyTransition(transitionState, transitionIntensity)

        if transitionState == "dropping" and not self.LastDropPrint or (self.LastDropPrint and CurTime() - self.LastDropPrint > 1) then
            print("Energy Transition:", transitionState, "Intensity:", transitionIntensity)
            self.LastDropPrint = CurTime()
        end
    end
end

--[[
    Detect beats in a specific frequency range
    @param frequencyRange: Key from FrequencyBands table
    @param beatType: Type of beat (Kick, Snare, etc.)
    @param threshold: Detection threshold multiplier
    @param cooldown: Minimum time between detections
    @return boolean, number: Whether beat detected, intensity
]]
function ENT:DetectFrequencyBeat(frequencyRange, beatType, threshold, cooldown)
    local currentTime = CurTime()

    -- Check cooldown
    if self.LastBeatTimes[beatType] and (currentTime - self.LastBeatTimes[beatType] < cooldown) then
        return false, 0
    end

    -- Get frequency band
    local band = self.FrequencyBands[frequencyRange]
    if not band or not self.FFTData or not self.PrevFFTData then
        return false, 0
    end

    -- Calculate spectral flux for this specific frequency range
    local flux = 0
    local energy = 0

    local startIdx = math.max(1, band[1])
    local endIdx = math.min(band[2], #self.FFTData)

    for i = startIdx, endIdx do
        local curr = self.FFTData[i] or 0
        local prev = self.PrevFFTData[i] or 0
        local diff = curr - prev

        -- Accumulate positive changes
        if diff > 0 then
            flux = flux + diff
        end

        -- Also track total energy in this band
        energy = energy + curr
    end

    -- Normalize by band size
    local bandSize = endIdx - startIdx + 1
    if bandSize > 0 then
        flux = flux / bandSize
        energy = energy / bandSize
    end

    -- Per-band flux history for automatic adaptation
    local bandHistory = self.FluxHistory[beatType] or {}
    table.insert(bandHistory, flux)
    if #bandHistory > self.FluxHistorySize then
        table.remove(bandHistory, 1)
    end
    self.FluxHistory[beatType] = bandHistory

    -- Compute adaptive stats per band
    local avgFlux = 0
    local variance = 0
    local sorted = table.Copy(bandHistory)
    table.sort(sorted)
    local medianFlux = (#sorted > 0) and sorted[math.floor(#sorted / 2) + 1] or 0.001

    if #bandHistory > 0 then
        for _, f in ipairs(bandHistory) do avgFlux = avgFlux + f end
        avgFlux = avgFlux / #bandHistory

        for _, f in ipairs(bandHistory) do variance = variance + (f - avgFlux) ^ 2 end
        variance = variance / #bandHistory
    else
        avgFlux = 0.001
    end
    local stdDev = math.sqrt(variance)

    -- Fully automatic threshold: Mean + scaled stdDev, with median offset
    local fluxThreshold = (avgFlux + (stdDev * 0.5)) + (medianFlux * 0.05)
    local energyThreshold = 0.2

    if flux > fluxThreshold and energy > energyThreshold then

        self.LastBeatTimes[beatType] = currentTime

        -- Add to beat history for tempo calculation
        table.insert(self.BeatHistory, currentTime)
        if #self.BeatHistory > 20 then
            table.remove(self.BeatHistory, 1)
        end

        -- Calculate intensity based on how much we exceeded the threshold
        local intensity = math.min(1, flux / (fluxThreshold + 1e-6))

        return true, intensity
    end

    return false, 0
end

-- ============================================
-- BEAT EVENT HANDLERS
-- ============================================

--[[
    Handle detected beats - trigger visual effects and screen shake
    @param intensity: Beat intensity (0-1)
    @param beatType: Type of beat detected
]]
function ENT:OnBeatDetected(intensity, beatType)

    -- Scale the model based on beat intensity
    self.BeatScale = math.min(2, 1 + (intensity * 0.5))

	/*
    -- Create particle effects if enabled
    if self.Config.Effects.EnableParticles then
        self:CreateBeatParticles(intensity, beatType)
    end
	*/

	/*
    -- Create screen shake for nearby players
    if self.Config.Effects.EnableScreenShake and intensity > 0.3 then
        local distance = self:GetListenerDistance()
        if distance < self.Config.Effects.MaxShakeDistance then
            -- Scale shake power based on distance
            local power = (1 - distance / self.Config.Effects.MaxShakeDistance) * intensity
			util.ScreenShake(self:GetPos(), power * 5, 1, 0.2, self.Config.Effects.MaxShakeDistance) -- Origin -- Amplitude -- Frequency -- Duration -- Radius
        end
    end
	*/

    -- Trigger beat-specific visual effects
    self:OnBeatDrop(intensity, beatType)
end

--[[
    Handle specific visual effects for different beat types
    @param intensity: Beat intensity
    @param beatType: Type of beat (Kick, Snare, HiHat, Clap)
]]
function ENT:OnBeatDrop(intensity, beatType)
	if intensity < 0.9 then return end

	if not self.BeatTracker then self.BeatTracker = {} end
	self.BeatTracker[beatType] = intensity

	local Segments = 12

	self:CreateCircularParticles(self.PartyCenter, "radio_speaker_beat01", self.PartyRadius, Segments, self.PartyHeight, 0)

	-- local effectsA = {"zpc2_oneshot_red","zpc2_oneshot_green","zpc2_oneshot_blue","zpc2_oneshot_white","zpc2_oneshot_violett","zpc2_oneshot_orange"}
	-- local effects = {"zpc2_burst_medium_blue", "zpc2_burst_medium_cyan", "zpc2_burst_medium_green", "zpc2_burst_medium_white"}
	-- local effectsA = {"zpc2_sparktower_blue","zpc2_sparktower_red","zpc2_sparktower_green","zpc2_sparktower_orange","zpc2_sparktower_pink","zpc2_sparktower_cyan","zpc2_sparktower_violett"}

	if beatType == "Kick" then
		self:CreateCircularParticles(self.PartyCenter, "zpc2_cake_explosion_red", self.PartyRadius, Segments, self.PartyHeight, 0)
	elseif beatType == "Snare" then
		self:CreateCircularParticles(self.PartyCenter, "zpc2_burst_medium_violett", self.PartyRadius, Segments, self.PartyHeight, 0)
	elseif beatType == "HiHat" then
		self:CreateCircularParticles(self.PartyCenter, "zpc2_sparktower_blue", self.PartyRadius, Segments, self.PartyHeight, 0)
	elseif beatType == "Clap" then
		self:CreateCircularParticles(self.PartyCenter, "zpc2_oneshot_green", self.PartyRadius, Segments, self.PartyHeight, 0)
	end
end

-- ============================================
-- ADVANCED PATTERN DETECTION
-- ============================================

--[[
    Detect vocal onsets in the mid-frequency range
    Vocals typically have rapid energy changes and sit in 1-4kHz
    @return boolean, number: Whether vocal detected, intensity
]]
function ENT:DetectVocalOnset()
    local currentTime = CurTime()

    -- Initialize vocal history if needed
    if not self.VocalHistory then
        self.VocalHistory = {}
        self.LastVocalTime = 0
        self.VocalEnergySmooth = 0
    end

    -- Shorter cooldown for rapid vocal changes
    if currentTime - self.LastVocalTime < 0.1 then
        return false, 0
    end

    -- Get mid-range frequencies where vocals live
    local band = self.FrequencyBands["Mid"]
    if not band or not self.FFTData then return false, 0 end

    -- Calculate energy in vocal range
    local vocalEnergy = 0
    local startIdx = math.max(1, band[1])
    local endIdx = math.min(band[2], #self.FFTData)

    for i = startIdx, endIdx do
        vocalEnergy = vocalEnergy + (self.FFTData[i] or 0)
    end
    vocalEnergy = vocalEnergy / (endIdx - startIdx + 1)

    -- Smooth the energy to reduce noise
    self.VocalEnergySmooth = Lerp(0.3, self.VocalEnergySmooth, vocalEnergy)

    -- Store history
    table.insert(self.VocalHistory, vocalEnergy)
    if #self.VocalHistory > 30 then
        table.remove(self.VocalHistory, 1)
    end

    -- Calculate average and deviation
    local avgEnergy = 0
    for _, e in ipairs(self.VocalHistory) do
        avgEnergy = avgEnergy + e
    end
    avgEnergy = avgEnergy / #self.VocalHistory

    -- Detect onset when energy spikes above average
    local threshold = avgEnergy * 1.3
    if vocalEnergy > threshold and vocalEnergy > 0.2 then
        self.LastVocalTime = currentTime
        local intensity = math.min(1, (vocalEnergy - threshold) / threshold)
        return true, intensity
    end

    return false, 0
end

--[[
    Detect consistent bassline patterns (not just kicks)
    Looks for rhythmic low-frequency patterns
    @return boolean, number, string: Pattern detected, confidence, pattern type
]]
function ENT:DetectBasslineGroove()
    -- Initialize bassline tracking
    if not self.BasslineTracker then
        self.BasslineTracker = {
            history = {},
            patternBuffer = {},
            lastBassTime = 0,
            patternConfidence = 0,
            currentPattern = "none"
        }
    end

    local currentTime = CurTime()
    local tracker = self.BasslineTracker

    -- Get bass energy
    local bassEnergy = self:GetFrequencyIntensity("Bass")

    -- Record bass energy history
    table.insert(tracker.history, {
        time = currentTime,
        energy = bassEnergy
    })

    -- Keep history limited
    while #tracker.history > 100 do
        table.remove(tracker.history, 1)
    end

    -- Need enough history to detect patterns
    if #tracker.history < 32 then
        return false, 0, "none"
    end

    -- Detect peaks in bass energy
    local peaks = {}
    for i = 2, #tracker.history - 1 do
        local prev = tracker.history[i-1].energy
        local curr = tracker.history[i].energy
        local next = tracker.history[i+1].energy

        -- Peak detection
        if curr > prev and curr > next and curr > 0.3 then
            table.insert(peaks, tracker.history[i].time)
        end
    end

    -- Need at least 4 peaks to detect a pattern
    if #peaks < 4 then
        return false, 0, "none"
    end

    -- Calculate intervals between peaks
    local intervals = {}
    for i = 2, #peaks do
        table.insert(intervals, peaks[i] - peaks[i-1])
    end

    -- Check for consistent intervals (bassline groove)
    local avgInterval = 0
    for _, interval in ipairs(intervals) do
        avgInterval = avgInterval + interval
    end
    avgInterval = avgInterval / #intervals

    -- Calculate deviation from average
    local deviation = 0
    for _, interval in ipairs(intervals) do
        deviation = deviation + math.abs(interval - avgInterval)
    end
    deviation = deviation / #intervals

    -- Low deviation means consistent pattern
    local consistency = 1 - math.min(1, deviation / avgInterval)

    -- Determine pattern type based on tempo
    local bpm = 60 / avgInterval
    local patternType = "none"

    if consistency > 0.7 then
        if bpm < 90 then
            patternType = "slow_groove"
        elseif bpm < 120 then
            patternType = "mid_groove"
        elseif bpm < 140 then
            patternType = "fast_groove"
        else
            patternType = "rapid_groove"
        end

        tracker.patternConfidence = consistency
        tracker.currentPattern = patternType

        return true, consistency, patternType
    end

    return false, 0, "none"
end

--[[
    Detect energy build-ups and drops
    Common in EDM and electronic music
    @return string: "building", "dropping", "steady"
]]
function ENT:DetectEnergyTransition()
    -- Initialize transition detection
    if not self.TransitionDetector then
        self.TransitionDetector = {
            energyHistory = {},
            state = "steady",
            buildStartTime = 0,
            dropTime = 0,
            peakEnergy = 0
        }
    end

    local detector = self.TransitionDetector
    local currentTime = CurTime()

    -- Calculate total energy across all frequencies
    local totalEnergy = 0
    if self.FFTData then
        for i = 1, #self.FFTData do
            totalEnergy = totalEnergy + (self.FFTData[i] or 0)
        end
        totalEnergy = totalEnergy / #self.FFTData
    end

    -- Store energy history
    table.insert(detector.energyHistory, {
        time = currentTime,
        energy = totalEnergy
    })

    -- Limit history size
    while #detector.energyHistory > 150 do
        table.remove(detector.energyHistory, 1)
    end

    -- Need enough history
    if #detector.energyHistory < 60 then
        return "steady", 0
    end

    -- Calculate energy trend over different time windows
    local shortWindow = 20  -- ~0.6 seconds
    local longWindow = 60   -- ~1.8 seconds

    local shortAvg = 0
    local longAvg = 0

    -- Calculate short-term average (recent)
    for i = #detector.energyHistory - shortWindow + 1, #detector.energyHistory do
        if detector.energyHistory[i] then
            shortAvg = shortAvg + detector.energyHistory[i].energy
        end
    end
    shortAvg = shortAvg / shortWindow

    -- Calculate long-term average
    for i = #detector.energyHistory - longWindow + 1, #detector.energyHistory do
        if detector.energyHistory[i] then
            longAvg = longAvg + detector.energyHistory[i].energy
        end
    end
    longAvg = longAvg / longWindow

    -- Track peak energy
    detector.peakEnergy = math.max(detector.peakEnergy * 0.9, totalEnergy)

    -- Detect build-up: steadily increasing energy
    local energySlope = shortAvg - longAvg
    if energySlope > 0.05 and totalEnergy > longAvg * 1.2 then
        -- Building up
        if detector.state ~= "building" then
            detector.buildStartTime = currentTime
        end
        detector.state = "building"

        -- Calculate build intensity (0-1)
        local buildDuration = currentTime - detector.buildStartTime
        local intensity = math.min(1, buildDuration / 5) * math.min(1, energySlope * 10)

        return "building", intensity

    elseif totalEnergy > detector.peakEnergy * 0.85 and detector.state == "building" then
        -- Drop detected! (high energy after build)
        detector.state = "dropping"
        detector.dropTime = currentTime

        return "dropping", 1.0

    elseif detector.state == "dropping" and currentTime - detector.dropTime < 0.5 then
        -- Still in drop phase
        local dropProgress = (currentTime - detector.dropTime) / 0.5
        return "dropping", 1 - dropProgress

    else
        -- Steady state
        detector.state = "steady"
        return "steady", 0
    end
end

--[[
    Visualize vocal onsets with ripple effects
    @param intensity: Vocal intensity (0-1)
]]
function ENT:OnVocalDetected(intensity)
    -- Create ripple effect at different height
    local pos = self:LocalToWorld(Vector(0,0,2))

    -- Color based on vocal intensity
	local color = Color(self.CurrentColor.r,self.CurrentColor.g, self.CurrentColor.b, 255 * intensity)

    -- Store ripple for rendering
    if not self.VocalRipples then self.VocalRipples = {} end

    table.insert(self.VocalRipples, {
        pos = pos,
        startTime = CurTime(),
        intensity = intensity,
        color = color
    })

    -- Clean old ripples
    for i = #self.VocalRipples, 1, -1 do
        if CurTime() - self.VocalRipples[i].startTime > 2 then
            table.remove(self.VocalRipples, i)
        end
    end
end

--[[
    Visualize bassline patterns with ground waves
    @param confidence: Pattern detection confidence
    @param patternType: Type of groove detected
]]
function ENT:OnBasslineGrooveDetected(confidence, patternType)
    -- Create ground wave effect
    if not self.GrooveWaves then self.GrooveWaves = {} end

    -- Add new wave
    table.insert(self.GrooveWaves, {
        startTime = CurTime(),
        radius = 0,
        pattern = patternType,
        confidence = confidence
    })

    -- Limit waves
    while #self.GrooveWaves > 50 do
        table.remove(self.GrooveWaves, 1)
    end
end

--[[
    Visualize energy transitions (build-ups and drops)
    @param state: "building", "dropping", or "steady"
    @param intensity: Transition intensity
]]
function ENT:OnEnergyTransition(state, intensity)
    if state == "building" then
        -- Create ascending particles during build-up
        self:CreateBuildUpEffect(intensity)

    elseif state == "dropping" then
        -- Create explosion effect on drop
        self:CreateDropEffect(intensity)
    end

    -- Store state for rendering
    self.CurrentTransitionState = state
    self.TransitionIntensity = intensity
end

--[[
    Create build-up visual effect
    @param intensity: Build intensity (0-1)
]]
function ENT:CreateBuildUpEffect(intensity)
    local pos = self:GetPos()

    -- Create rising particles around the radio
    local particleCount = math.Clamp(math.floor(5 + intensity * 100),12,120)
    for i = 1, particleCount do
        local angle = (i / particleCount) * math.pi * 2
        local radius = 300 + (1500 * intensity)

		local particlePos = pos + Vector(math.cos(angle) * radius, math.sin(angle) * radius, 0)

        -- Use existing particle effect
        ParticleEffect("zpc2_burst_tiny_orange", particlePos, Angle(0, 0, 0), nil)
    end

    -- Store build-up data for rendering
    self.BuildUpIntensity = intensity
end

--[[
    Create drop visual effect
    @param intensity: Drop intensity (0-1)
]]
function ENT:CreateDropEffect(intensity)
    local pos = self:GetPos() --+ Vector(0, 0, 100 * self.ModelScale)

    -- Big explosion effect
    ParticleEffect("zpc2_cake_explosion_red", pos, Angle(0, 0, 0), nil)

    -- Radial burst
    for i = 1, 12 do
        local angle = (i / 12) * math.pi * 2
		local burstPos = pos + Vector(math.cos(angle) * 400, math.sin(angle) * 400, 0)
        -- ParticleEffect("zpc2_sparktower_red", burstPos, Angle(0, 0, 0), nil)
		ParticleEffect("zpc2_burst_big_pink", burstPos, Angle(0, 0, 0), nil)
    end

    -- Screen shake for drops
    if self.Config.Effects.EnableScreenShake then
        util.ScreenShake(self:GetPos(), intensity * 10, 5, 0.5, 1000)
    end

    -- Store drop data
    self.LastDropTime = CurTime()
    self.DropIntensity = intensity
end

--[[
    Draw vocal ripples in 3D2D
]]
function ENT:DrawVocalRipples()
    if not self.VocalRipples then return end

    for _, ripple in ipairs(self.VocalRipples) do
        local age = CurTime() - ripple.startTime
        local maxAge = 2

        if age < maxAge then
            local progress = age / maxAge
            local radius = progress * 500
            local alpha = (1 - progress) * 255

            cam.Start3D2D(ripple.pos, Angle(0, 0, 0), 2)
                surface.SetDrawColor(ripple.color.r, ripple.color.g, ripple.color.b, alpha)
				surface.SetMaterial(mat_ring_wave_additive)
				surface.DrawTexturedRect(-radius/2,-radius/2,radius,radius)
                --surface.DrawCircle(0, 0, radius, ripple.color)
            cam.End3D2D()
        end
    end
end

--[[
    Draw bassline groove waves on ground
]]
function ENT:DrawGrooveWaves()
    if not self.GrooveWaves then return end

    for i, wave in ipairs(self.GrooveWaves) do
        local age = CurTime() - wave.startTime
		local maxAge = 2

		local progress = age / maxAge
		local radius = progress * 1000

        if radius > 1500 then table.remove(self.GrooveWaves,i) continue end

        local alpha = (1 - radius / 1000) * 255 * wave.confidence

        -- Color based on pattern type
        local color = Color(255, 100, 100, alpha)
        if wave.pattern == "slow_groove" then
            color = Color(100, 100, 255, alpha)
        elseif wave.pattern == "fast_groove" then
            color = Color(255, 255, 100, alpha)
        elseif wave.pattern == "rapid_groove" then
            color = Color(255, 100, 255, alpha)
        end

        cam.Start3D2D(self:GetPos() + Vector(0, 0, 2), Angle(0, 0, 0), 1)
			surface.SetDrawColor(color.r, color.g, color.b,alpha)
			surface.SetMaterial(mat_ring_wave_additive)
			surface.DrawTexturedRect(-radius/2,-radius/2,radius,radius)
        cam.End3D2D()
    end
end

--[[
    Draw build-up/drop transition effects
]]
function ENT:DrawTransitionEffects()
    if not self.CurrentTransitionState then return end

    if self.CurrentTransitionState == "building" then
        -- Draw ascending energy bars
        local intensity = (self.TransitionIntensity or 0) * 10
		if intensity > 0.001 then
	        cam.Start3D2D(self:LocalToWorld(Vector(-25,0,30)),self:LocalToWorldAngles(Angle(0, -90, 90)), 0.15)

	            -- Energy meter
	            local barHeight = 200 * intensity
	            local barWidth = 40

	            -- Background
	            surface.SetDrawColor(0, 0, 0, 100)
	            surface.DrawRect(-barWidth/2, -100, barWidth,200)

	            -- Energy bar
	            local color = HSVToColor(120 * (1 - intensity), 1, 1)
	            surface.SetDrawColor(color.r, color.g, color.b, 255)
	            surface.DrawRect(-barWidth/2, 100 - barHeight, barWidth, barHeight)

	            -- Text
				draw.SimpleText("BUILD", "DermaLarge", 0, -120, Color(255, 255, 255, 255 * intensity), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	        cam.End3D2D()
		end

    elseif self.CurrentTransitionState == "dropping" then
        -- Flash effect for drop
        if self.LastDropTime and CurTime() - self.LastDropTime < 0.3 then
            local flashAlpha = (1 - (CurTime() - self.LastDropTime) / 0.3) * 255

            cam.Start3D2D(self:GetPos() + Vector(0,0,2) , self:LocalToWorldAngles(Angle(0,-90,0)), 1)
                surface.SetDrawColor(255, 255, 255, flashAlpha)
                surface.DrawCircle(0, 0, 50, Color(255, 255, 255, flashAlpha))
            cam.End3D2D()
        end
    end
end

-- ============================================
-- VISUAL EFFECTS
-- ============================================

--[[
    Helper function to draw with additive blending
    Makes overlapping colors brighter instead of darker
    @param call: Function to execute with additive blending
]]
local function BlendAdditive(call)
    zclib.Blendmodes.Blend("Additive", false, call)
end

--[[
    Draw rotating visual rings around the entity
    @param col: Color of the rings
    @param scale: Size multiplier
    @param rot: Rotation angle
    @param offset: Ring offset multiplier
]]
local function DrawRing(col, scale, rot, offset)
    -- Draw multiple overlapping rings for glowing effect
    BlendAdditive(function()
        surface.SetMaterial(zqs_crosshair03_glow)
        surface.SetDrawColor(col)
        surface.DrawTexturedRectRotated(0, 0, 330 * scale, 330 * scale, -rot * offset)
    end)
    BlendAdditive(function()
        surface.SetMaterial(sprite_catch_glow)
        surface.SetDrawColor(col)
        surface.DrawTexturedRectRotated(0, 0, 300 * scale, 300 * scale, -rot * offset)
    end)
    BlendAdditive(function()
        surface.SetMaterial(zqs_crosshair03_glow)
        surface.SetDrawColor(col)
        surface.DrawTexturedRectRotated(0, 0, 330 * scale, 330 * scale, rot * offset)
    end)
    BlendAdditive(function()
        surface.SetMaterial(sprite_catch_glow)
        surface.SetDrawColor(col)
        surface.DrawTexturedRectRotated(0, 0, 300 * scale, 300 * scale, rot * offset)
    end)
end

--[[
    Draw shader effect over model
    @param ent: Entity to draw on
    @param mat: Material to use
    @param col: Color modulation
    @param offset: Size offset
]]
local function DrawShader(ent, mat, col, offset)
    -- Temporarily switch to beach ball model for sphere effect
    ent:SetModel("models/dlaor/dbeachball.mdl")

    -- Scale the model
    local matrix = Matrix()
    matrix:Scale(Vector(1, 1, 1) * (1.2 + offset))
    ent:EnableMatrix("RenderMultiply", matrix)

    -- Apply shader with color
    render.MaterialOverride(mat)
    render.SetColorModulation((1/255) * col.r, (1/255) * col.g, (1/255) * col.b)
    ent:DrawModel()

    -- Reset rendering
    render.SetColorModulation(1, 1, 1)
    render.MaterialOverride()
    ent:DisableMatrix("RenderMultiply")

    -- Restore original model
    ent:SetModel("models/spg/gryffindor/lamp.mdl")
end

--[[
    Create circular particle effects around entity
    @param center: Center position for effects
    @param particleName: Name of particle effect
    @param radius: Circle radius
    @param numParticles: Number of particles in circle
    @param height: Vertical offset
    @param offset: Angular offset
]]
function ENT:CreateCircularParticles(center, particleName, radius, numParticles, height, offset)

	offset = CurTime() * 10

    local origin = center -- + Vector(0, 0, 30 * self:GetModelScale())
    local angleStep = 360 / numParticles

    for i = 0, numParticles - 1 do
        local angle = math.rad(i * angleStep + offset)
        local posX = math.cos(angle) * radius
        local posY = math.sin(angle) * radius
        local particlePos = origin + Vector(posX, posY, height)

        -- Orient particle to face center
        local ang = (origin - particlePos):Angle()
        --ang:RotateAroundAxis(ang:Right(), -90)

		--debugoverlay.Sphere(MainEffectPos,25,0.1,Color( 255, 255, 255, 100 ))

		--debugoverlay.Axis(particlePos, ang,10,1,false)

        ParticleEffect(particleName, particlePos, ang, nil)
    end
end

--[[
    Create particle burst effect for beats
    @param intensity: Effect intensity
    @param beatType: Type of beat
]]
function ENT:CreateBeatParticles(intensity, beatType)
    if not self.Config.Effects.EnableParticles then return end

    local pos = self:GetPos()

    -- Create particle emitter
    local success, emitter = pcall(ParticleEmitter, pos,true)
    if not success or not emitter then return end

    -- Scale particle count based on intensity
    local particleCount = math.Clamp(math.floor(10 * intensity), 1, self.Config.Performance.MaxParticles)

	local ang = self:LocalToWorldAngles(Angle(90,0,0))

    for i = 1, particleCount do
        --local particle = emitter:Add("sprites/light_glow02_add", pos)
		local particle = emitter:Add("particle/particle_ring_wave_additive", pos)
        if particle then
            -- Create radial burst pattern
            local angle = (i / particleCount) * math.pi * 2
            local speed = self.PartyRadius * intensity
			local velocity = Vector(math.cos(angle) * speed, math.sin(angle) * speed, 0)

            -- Configure particle properties
			particle:SetAngles(ang)
            --particle:SetVelocity(velocity)
            particle:SetDieTime(1)
            particle:SetStartAlpha(255)
            particle:SetEndAlpha(0)
            particle:SetStartSize(0)
            particle:SetEndSize(500)
            particle:SetColor(self.CurrentColor.r, self.CurrentColor.g, self.CurrentColor.b)
            particle:SetGravity(Vector(0, 0, 0))
        end
    end

    emitter:Finish()
end

--[[
    Update visual color based on audio frequencies
    Creates dynamic color changes synced to music
]]
function ENT:UpdateVisualColor()
    -- Generate color from audio properties
    local hue = (CurTime() * 30 + self.BassIntensity * 100) % 360
    local sat = math.Clamp(0.5 + self.TrebleIntensity * 0.5, 0, 1)
    local val = math.Clamp(0.5 + self.VisualIntensity * 0.5, 0, 1)

    self.TargetColor = HSVToColor(hue, sat, val)

    -- Smooth color transitions
    self.CurrentColor = Color(
        Lerp(0.1, self.CurrentColor.r, self.TargetColor.r),
        Lerp(0.1, self.CurrentColor.g, self.TargetColor.g),
        Lerp(0.1, self.CurrentColor.b, self.TargetColor.b)
    )
end

--[[
    Check if current intensity indicates an epic moment
    @param level: Threshold level (1-10)
    @return boolean: True if epic
]]
function ENT:IsEpic(level)
    return self.VisualIntensity > (level * 0.05)
end

--[[
    Update bass-frequency visual effects
    Creates ground rings and screen shake
    @param intensity: Bass intensity (0-1)
]]
function ENT:OnBassUpdate(intensity)
    if intensity <= 0.2 then return end

    local glow_col = Color(self.fft_col01.r, self.fft_col01.g, self.fft_col01.b, 50)


    -- Draw ground rings
	cam.Start3D2D(self:LocalToWorld(Vector(0, 0, 2)), self:LocalToWorldAngles(Angle(0, 0, 0)), math.Clamp(self.fft_scale, 0.4, 50))
        -- Background glow
        surface.SetMaterial(radial_shadow)
        surface.SetDrawColor(glow_col)
        surface.DrawTexturedRectRotated(0, 0, 500, 500, 0)

        -- Rotating rings
        for i = 1, self.fft_ring_count do
            local alpha = math.Clamp(200 - 25 * i, 0, 255)
			DrawRing(Color(self.fft_col02.r, self.fft_col02.g, self.fft_col02.b, alpha), i * 0.15, self.fft_rot, i)
        end
    cam.End3D2D()

	/*
    -- Distance-based screen shake
    local dist = self:GetListenerDistance()
    if dist < 600 then
        local shake_dist = 600
        local squareDist = shake_dist * shake_dist
        local shake_strength = squareDist - math.Clamp(dist ^ 2, 0, squareDist)
        local shake_intens = (1 / squareDist) * shake_strength
		util.ScreenShake(self:GetPos(), intensity * 0.1, 1, 0.1, intensity * shake_intens * 10)
    end
	*/
end

--[[
    Update treble-frequency visual effects
    Creates floating rings above the radio
    @param intensity: Treble intensity (0-1)
]]
function ENT:OnTrebleUpdate(intensity)
	if not self.PartyCenter then return end

	local glow_col = Color(self.fft_col02.r, self.fft_col02.g, self.fft_col02.b, 50)
	local dist = self:GetListenerDistance()


	render.SetMaterial(laser)
	render.DrawBeam(self:GetPos(), self.PartyCenter, 200, 0, 0, self.fft_col02)

	cam.Start3D2D(self.PartyCenter, self.LocalViewAng or angle_zero, self.fft_scale)
        surface.SetMaterial(sprite_flare)
        surface.SetDrawColor(self.fft_col02)
        surface.DrawTexturedRectRotated(0, 0, 200, 200, 0)

		surface.SetMaterial(sprite_flare)
		surface.SetDrawColor(255,255,255,100)
		surface.DrawTexturedRectRotated(0, 0, 100, 100, 0)
    cam.End3D2D()


    if intensity <= 0.05 then return end

    -- Disable depth testing for close range
    --cam.IgnoreZ(dist < 1000)
	cam.Start3D2D(self:LocalToWorld(Vector(0, 0, 2)), self.LocalViewAng or angle_zero, self.fft_scale)
        -- Background glow
        surface.SetMaterial(radial_shadow)
        surface.SetDrawColor(glow_col)
        surface.DrawTexturedRectRotated(0, 0, 300, 300, 0)

        -- Epic moment rings
        --if self:IsEpic(5) then
            for i = 1, self.fft_ring_count do
                local alpha = math.Clamp(200 - 25 * i, 0, 200)
				DrawRing(Color(self.fft_col02.r, self.fft_col02.g, self.fft_col02.b, alpha), i * 0.15, self.fft_rot, i)
            end
        --end
    cam.End3D2D()
    --cam.IgnoreZ(false)
end

--[[
    Update volume-based visual effects
    Handles dynamic lighting and hologram effects
    @param intensity: Overall volume intensity (0-1)
]]
function ENT:OnVolumeUpdate(intensity)
    if intensity <= 0.01 then return end

    -- Create dynamic light
    local dlight = DynamicLight(self:EntIndex())
    if dlight then
        dlight.pos = self:GetPos()
        dlight.r = self.fft_col03.r
        dlight.g = self.fft_col03.g
        dlight.b = self.fft_col03.b
        dlight.brightness = 5 * self.fft_scale
        dlight.decay = 1000
        dlight.size = 4000 * self.fft_scale
        dlight.dietime = CurTime() + 1
    end

    -- Trigger epic shader time
    if self:IsEpic(7) then
        self.EpicShaderTime = CurTime() + 0.5
    end

	/*
    if self.EpicShaderTime > CurTime() then
        render.CullMode(1)
        local nextSize = 1.5
        for i = 1, self.fft_sphere_count do
            DrawShader(self, shader_clouds, self.fft_col03, nextSize * self.fft_scale)
            nextSize = nextSize + (i * 0.15)
        end
        render.CullMode(0)
    end
	*/

    -- Handle hologram model changes
    if self:IsEpic(2) then
        if not self.HoloModelChange or CurTime() > self.HoloModelChange then
            local option = not self.HoloLastOption
            self.HoloModel = self.ModelList[math.random(#self.ModelList)]
            self.HoloLastOption = option
            self.HoloModelChange = CurTime() + 10
            self.EpicShaderTime = CurTime() + 10
            self.FlipRotationDir = option
        end
    end

	if not self.HoloModel then self.HoloModel = self.ModelList[math.random(#self.ModelList)] end

    -- Render hologram model
    if self.HoloModel then
        -- Set hologram model
        self:SetModel(self.HoloModel)
        self:SetRenderOrigin(self.PartyCenter)

        -- Update rotation
        if not self.next_rot_target_check or CurTime() > self.next_rot_target_check then
			local val = self.fft_tempo_avg * 100
            self.rot_speed_target = (self.rot_speed_target or 0) + (self.FlipRotationDir and val or -val)
            self.next_rot_target_check = CurTime() + 1
        end

        self.rot_speed_smooth = Lerp(FrameTime() * 0.5, self.rot_speed_smooth or 0, self.rot_speed_target)
        self:SetRenderAngles(self:LocalToWorldAngles(Angle(0, self.rot_speed_smooth, 0)))

        -- Set animation
        if self:LookupSequence("menu_walk") ~= -1 then
            self:SetSequence("menu_walk")
            self.AnimCycle = (self.AnimCycle or 0) + FrameTime()
            if self.AnimCycle > 1 then self.AnimCycle = 0 end
            self:SetCycle(self.AnimCycle)
        elseif self:LookupSequence("taunt_salute") ~= -1 then
            self:SetSequence("taunt_salute")
            self.AnimCycle = (self.AnimCycle or 0) + FrameTime()
            if self.AnimCycle > 1 then self.AnimCycle = 0 end
            self:SetCycle(self.AnimCycle)
        end

        -- Scale model to fit
        local min, max = self:GetRenderBounds()
        local size = max - min
        local maxDimension = math.max(size.x, size.y, size.z)
        local scale = 200 / maxDimension

        local matrix = Matrix()
        matrix:Scale(Vector(scale, scale, scale) * (0.5 + self.fft_scale))
        self:EnableMatrix("RenderMultiply", matrix)

        -- Apply color modulation
        render.SetColorModulation(
            (1 / 255) * self.fft_col02.r,
            (1 / 255) * self.fft_col02.g,
            (1 / 255) * self.fft_col02.b
        )

        -- Render with glow effect
        render.MaterialOverride(emptool_glow)
        self:DrawModel()
        render.MaterialOverride()

        -- Render with cloud shader
        render.MaterialOverride(shader_clouds)
        self:DrawModel()
        render.MaterialOverride()

        -- Reset rendering
        render.SetColorModulation(1, 1, 1)
        self:DisableMatrix("RenderMultiply")

        -- Restore original model
        self:SetModel("models/spg/gryffindor/lamp.mdl")
        self:SetRenderOrigin(self:LocalToWorld(Vector(0, 0, 0)))
        self:SetRenderAngles(self:LocalToWorldAngles(Angle(0, 0, 0)))
    end
end

-- ============================================
-- RENDERING
-- ============================================

--[[
    Main think function - updates model scale and animations
]]
function ENT:Think()
    -- Smooth beat scale back to normal
    if self.BeatScale and self.BeatScale > 1 then
        self.BeatScale = Lerp(FrameTime() * 0.5, self.BeatScale, 1)
    end

    if self:IsRadioPlaying() then
        -- Apply beat scale with smoothing
        local targetScale = self.ModelScale * (self.BeatScale or 1)
        self.SmoothScale = Lerp(FrameTime() * 4, self.SmoothScale or 0, targetScale)
        self:SetModelScale(self.SmoothScale, 0)
    else
        -- Reset to base scale when not playing
        self:SetModelScale(self.ModelScale, 0)
    end

	self.SmoothIntensity = Lerp(FrameTime() * 0.5,self.SmoothIntensity or 0,self.VisualIntensity)
	self.SmoothVocalEnergyIntensity = Lerp(FrameTime() * 0.5,self.SmoothVocalEnergyIntensity or 0,(self.VocalEnergySmooth or 0) * 2)

	if self.VocalEnergySmooth and self.VocalEnergySmooth > 0 then
		local sin = math.sin(CurTime())
		local cos = math.cos(CurTime())

		local intensity = self.SmoothIntensity
		local vocal = self.SmoothVocalEnergyIntensity

		local BaseRad = 100
		local SinRad = math.abs(200 * sin)
		local AnimRad = 400 * intensity

		local radius = math.Clamp(BaseRad + SinRad + AnimRad,BaseRad,5000)

		local numParticles = 12

		local height = (200 * vocal) + math.abs(200 * cos)

		local center = self:LocalToWorld( Vector(0, 0,  radius + height) )
		self.PartyCenter = center
		self.PartyRadius = radius
		self.PartyHeight = -height

	    -- Trigger extra particles during intense moments
	    if ( not self.NextBeat or CurTime() > self.NextBeat) then
			self.NextBeat = CurTime() + 0.01
	        self:CreateCircularParticles(center, "radio_speaker_beat01", radius, numParticles, -height, 0)
	    end
	end

    -- Continue thinking
    self:SetNextClientThink(CurTime())
    return true
end

--[[
    Main rendering function
    Handles LOD and calls appropriate visual effects
]]
function ENT:DrawTranslucent()
    -- Draw the base model
    self:DrawModel()

    -- Skip effects if not playing
    if not self:IsRadioPlaying() then return end

    -- Calculate LOD based on distance
    local distance = self:GetListenerDistance()
    if distance > self.Config.Performance.LODDistance then
        self.LODLevel = 2 -- Low detail
    elseif distance > self.Config.Performance.LODDistance / 2 then
        self.LODLevel = 1 -- Medium detail
    else
        self.LODLevel = 0 -- Full detail
    end

    -- Update FFT analysis at configured rate
    self.NextUpdateTime = CurTime() + self.Config.Performance.UpdateRate
    self:AnalyzeFFT()

    -- Update view angle for 3D2D rendering
    self.LocalViewAng = Angle(90, LocalPlayer():EyeAngles().y - 90, 90)

    -- Draw effects based on LOD
    if self.LODLevel < 2 then
        self:DrawDynamicLighting()
    end

	if self.LODLevel == 0 then
        self:DrawFrequencyBars()

        -- ADD THESE NEW DRAW CALLS
        self:DrawVocalRipples()
        self:DrawGrooveWaves()
        self:DrawTransitionEffects()
    end

	if LocalPlayer():IsSuperAdmin() then
		self:DrawBeatIndicator()
		self:DrawDebugInfo()
	end

    -- Keep audio positioned at entity
    if IsValid(self.SoundChannel) then
        self.SoundChannel:SetPos(self:GetPos())
    end


	if not self.PartyRadius then return end

	local angleStep = 360 / 12
	for i = 0, 12 - 1 do
		local angle = math.rad(i * angleStep + (CurTime() * 10))
		local posX = math.cos(angle) * self.PartyRadius
		local posY = math.sin(angle) * self.PartyRadius
		local particlePos = self.PartyCenter + Vector(posX, posY, self.PartyHeight)
		render.SetMaterial(laser)
		render.DrawBeam(particlePos, self.PartyCenter, 50, 0, 0, self.fft_col02)
	end
end

--[[
    Create 2D HUD Beat Indicator
    Visualizes Beats on the Screen
]]
function ENT:DrawBeatIndicator()
	if not self.BeatTracker then return end

	local scale = 0.5
	local sw,sh = ScrW(),ScrH()
	local w,h = 600 * scale,300 * scale
	local gap = 10 * scale
	local x,y = sw - w - gap, gap

	cam.Start2D()
		surface.SetDrawColor(0,0,0,200)
		surface.DrawRect(x,y, w, h)

		local count = 0
		for k,v in pairs(self.BeatTracker) do
			local bw,bh = (w - (gap * 3)) / 2,(h - (gap * 3)) / 2

			local bx = x + ((gap + bw) * count) + gap

			if count >= 2 then bx = bx - ((gap + bw) * 2) end

			local by = y + gap + (count >= 2 and bh + gap or 0)

			local col = HSVToColor(360 / 4 * count,0.5,1)

			surface.SetDrawColor(col.r,col.g,col.b,math.Clamp(255 * v,5,255))
			surface.DrawRect(bx,by,bw,bh)

			draw.SimpleText(k or "nil", "DermaLarge", bx + (bw/2), by + (bh / 2) , Color(0,0,0,200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			self.BeatTracker[k] = Lerp(FrameTime() * 10,self.BeatTracker[k] or 0,0)

			count = count + 1
		end

		-- Outline Box
		surface.SetDrawColor( self.CurrentColor )
		surface.DrawOutlinedRect(x,y,w,h,1 )
	cam.End2D()
end

--[[
    Create dynamic lighting effects
    Pulses light based on music intensity
]]
function ENT:DrawDynamicLighting()
    if not self.Config.Effects.EnableLighting then return end

    local dlight = DynamicLight(self:EntIndex())
    if dlight then
        dlight.pos = self:GetPos() + ( self:GetUp() * (self:GetModelScale() * 30) )
        dlight.r = self.CurrentColor.r
        dlight.g = self.CurrentColor.g
        dlight.b = self.CurrentColor.b
        dlight.brightness = math.Clamp(2 + self.VisualIntensity * 3, 0, 5)
        dlight.size = math.Clamp(256 + self.BassIntensity * 1024, 100, 2048)
        dlight.decay = 1000
        dlight.dietime = CurTime() + 0.1
	end
end

--[[
    Draw frequency spectrum display
    Shows FFT bands as bars above the radio
]]
function ENT:DrawFrequencyBars()
    if not self.FFTData or #self.FFTData == 0 then return end

    -- Box size
	local bh = 60
	local bw = 400

    -- Current color
    local col = self.CurrentColor

	cam.Start3D2D(self:LocalToWorld(Vector(-10 * self:GetModelScale(), 0, 5 * self:GetModelScale())), self:LocalToWorldAngles(Angle(0, -90, 90)), 0.1)
        -- Background
        surface.SetDrawColor(0, 0, 0, 200)
        surface.DrawRect(-bw/2, -bh/2, bw, bh)

        -- Draw frequency bars
        local barCount = math.min(self.Config.FFT.Bands, #self.FFTData)
        local barWidth = 400 / barCount

        for i = 1, barCount do
            local height = math.min(bh, (self.FFTNormalized[i] or 0) * bh)
            local x = (-bw/2) + (i - 1) * barWidth

            -- Color based on frequency (low=red, high=blue)
            local hue = (i / barCount) * 120
            local color = HSVToColor(hue, 1, 1)

            surface.SetDrawColor(color.r, color.g, color.b, 255)
            surface.DrawRect(x, -bh / 2, barWidth - 2, height)
        end

        -- Draw song info if available
        if self.CurrentSong then
			draw.SimpleText(self.CurrentSong.artist or "Unknown", "DermaLarge", 0, -bh/2 + 5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
			draw.SimpleText(self.CurrentSong.name or "Unknown", "DermaDefault", 0, (bh/2) - 5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
        end

        -- Outline Box
    	surface.SetDrawColor( col.r, col.g, col.b, 255 )
		surface.DrawOutlinedRect( -bw/2, -bh/2, bw, bh,1 )

    cam.End3D2D()
end

--[[
    Draw debug information panel below the frequency bars in two columns
    Displays calculated values for the current song to aid debugging
]]
function ENT:DrawDebugInfo()
	local scale = 0.5
	local sw,sh = ScrW(),ScrH()
	local w,h = 600 * scale,1010 * scale
	local gap = 10 * scale
	local x,y = sw - w - gap, gap * 2 + 300 * scale

	-- Current color
    local col = self.CurrentColor

	cam.Start2D()

		-- Background
        surface.SetDrawColor(0, 0, 0, 200)
		surface.DrawRect(x,y, w, h)

    	-- Outline Box
    	surface.SetDrawColor( col.r, col.g, col.b, 255 )
		surface.DrawOutlinedRect(x,y,w,h,1 )

        -- Calculate average normalized FFT
        local avgFFT = 0
        local fftCount = 0
        for i = 1, #self.FFTNormalized do
            if self.FFTNormalized[i] and type(self.FFTNormalized[i]) == "number" then
                avgFFT = avgFFT + self.FFTNormalized[i]
                fftCount = fftCount + 1
            end
        end
        avgFFT = fftCount > 0 and (avgFFT / fftCount) or 0

        -- Calculate average flux from history
        local avgFlux = 0
        if self.FluxHistory and #self.FluxHistory > 0 then
            for _, flux in ipairs(self.FluxHistory) do
                avgFlux = avgFlux + flux
            end
            avgFlux = avgFlux / #self.FluxHistory
        end

		local deci = "%.4f"

		-- Debug information lines
		local debugLines = {
			{"Visual Intensity", string.format(deci, self.VisualIntensity or 0)},
			{"Bass Intensity", string.format(deci, self.BassIntensity or 0)},
			{"Treble Intensity", string.format(deci, self.TrebleIntensity or 0)},
			{"Tempo (avg s/beat)", string.format(deci, self.fft_tempo_avg or 0)},
			{"Max Energy", string.format(deci, self.CurrentMaxEnergy or 0)},
			{"SubBass Intensity", string.format(deci, self:GetFrequencyIntensity("SubBass") or 0)},
			{"LowMid Intensity", string.format(deci, self:GetFrequencyIntensity("LowMid") or 0)},
			{"Mid Intensity", string.format(deci, self:GetFrequencyIntensity("Mid") or 0)},
			{"HighMid Intensity", string.format(deci, self:GetFrequencyIntensity("HighMid") or 0)},
			{"Kick Threshold", string.format(deci, (self.AdaptiveThresholds and self.AdaptiveThresholds.Kick) or 0)},
			{"Snare Threshold", string.format(deci, (self.AdaptiveThresholds and self.AdaptiveThresholds.Snare) or 0)},
			{"HiHat Threshold", string.format(deci, (self.AdaptiveThresholds and self.AdaptiveThresholds.HiHat) or 0)},
			{"Clap Threshold", string.format(deci, (self.AdaptiveThresholds and self.AdaptiveThresholds.Clap) or 0)},
			{"Time since Kick", string.format(deci, CurTime() - (self.LastBeatTimes and self.LastBeatTimes.Kick or 0))},
			{"Time since Snare", string.format(deci, CurTime() - (self.LastBeatTimes and self.LastBeatTimes.Snare or 0))},
			{"Time since HiHat", string.format(deci, CurTime() - (self.LastBeatTimes and self.LastBeatTimes.HiHat or 0))},
			{"Time since Clap", string.format(deci, CurTime() - (self.LastBeatTimes and self.LastBeatTimes.Clap or 0))},
			{"Avg Flux", string.format(deci, avgFlux or 0)},
			{"Current Flux", string.format(deci, self.CurrentFlux or 0)},
			{"Avg Normalized FFT", string.format(deci, avgFFT or 0)},
			{"Vocal Intensity", string.format(deci, self.VocalEnergySmooth or 0)},
			{"Groove Type", tostring(self.BasslineTracker and self.BasslineTracker.currentPattern or "none")},
			{"Groove Confidence", string.format(deci, self.BasslineTracker and self.BasslineTracker.patternConfidence or 0)},
			{"Transition State", tostring(self.CurrentTransitionState or "steady")},
			{"Transition Intensity", string.format(deci, self.TransitionIntensity or 0)},
		}


        -- Draw two columns: first 10 lines on left, last 10 on right
        local yPos = y
        local lineHeight = 20

        for i = 1, #debugLines do
			if not debugLines[i] then continue end
            draw.SimpleText(tostring(debugLines[i][1]), "DermaDefault", x + gap, yPos + gap, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        	draw.SimpleText(":", "DermaDefault", x + gap + w / 2, yPos + gap, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
			draw.SimpleText(tostring(debugLines[i][2]), "DermaDefault", x + w - gap, yPos + gap, color_white, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
            yPos = yPos + lineHeight
        end
	cam.End2D()
end

-- ============================================
-- NETWORKING
-- ============================================

-- Handle play next song message
net.Receive("PartyRadio_PlayNext", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local songData = net.ReadTable()
    if not istable(songData) then return end

    ent.CurrentSong = songData
    if songData.url then
        ent:PlaySound(songData.url)
    end
end)

-- Handle stop playback message
net.Receive("PartyRadio_Stop", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    ent:StopMusic()
    ent.CurrentSong = nil
end)

-- Handle state update message
net.Receive("PartyRadio_UpdateState", function()
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "zeros_party_radio" then return end

    local isPlaying = net.ReadBool()
    local currentIndex = net.ReadUInt(16)
    local volume = net.ReadFloat()

    ent.Volume = math.Clamp(volume, 0, 1)

    if IsValid(ent.SoundChannel) then
        ent.SoundChannel:SetVolume(ent.Volume)
    end

    ent.IsPlaying = isPlaying
end)
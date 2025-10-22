-- ============================================
-- AUDIO ANALYSIS & BEAT DETECTION MODULE
-- ============================================
-- This module handles all FFT analysis, beat detection,
-- and advanced music pattern recognition

--[[
    Initialize frequency band mappings for more accurate beat detection
    Maps FFT bins to actual frequency ranges based on sample rate
]]
function ENT:InitializeFrequencyBands()
    self.FrequencyBands = self.Config.Frequencies  -- Use config ranges for grouped bands, no raw bin calcs
end

-- ============================================
-- FFT ANALYSIS
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
-- BEAT DETECTION
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
-- ADVANCED PATTERN DETECTION
-- ============================================

--[[
    Detect vocal presence and intensity in the audio
    Returns a continuous 0-1 value representing how much vocal content is present
    - 0.0 = Pure instrumental (no vocals)
    - 1.0 = Pure vocals (a cappella)
    - 0.5 = Mixed (vocals with instrumental)
    @return boolean, number: Whether vocals detected, intensity (0-1)
]]
function ENT:DetectVocalOnset()
    local currentTime = CurTime()

    -- Initialize vocal tracker if needed
    if not self.VocalTracker then
        self.VocalTracker = {
            -- Energy tracking
            vocalEnergyHistory = {},
            bassEnergyHistory = {},
            trebleEnergyHistory = {},

            -- Smoothed values
            vocalEnergySmooth = 0,
            vocalPresenceSmooth = 0,

            -- Detection state
            lastVocalTime = 0,
            calibrationSamples = 0,

            -- Calibration stats
            maxVocalEnergy = 0.01,
            maxBassEnergy = 0.01,
            avgVocalRatio = 0.5,
        }
    end

    local tracker = self.VocalTracker

    if not self.FFTData or #self.FFTData == 0 then
        return false, 0
    end

    -- Get frequency bands
    local vocalBand = self.FrequencyBands["Mid"]      -- 500Hz-2kHz (primary vocal range)
    local highMidBand = self.FrequencyBands["HighMid"] -- 2kHz-4kHz (vocal harmonics)
    local bassBand = self.FrequencyBands["Bass"]       -- Bass/instrumental
    local subBassBand = self.FrequencyBands["SubBass"] -- Deep bass/kick drums

    if not vocalBand or not bassBand then return false, 0 end

    -- Calculate energy in vocal frequencies (300Hz-4kHz)
    local vocalEnergy = 0
    local vocalCount = 0

    -- Primary vocal range (Mid)
    local startIdx = math.max(1, vocalBand[1])
    local endIdx = math.min(vocalBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        vocalEnergy = vocalEnergy + (self.FFTData[i] or 0)
        vocalCount = vocalCount + 1
    end

    -- Vocal harmonics range (HighMid) - weighted slightly less
    if highMidBand then
        startIdx = math.max(1, highMidBand[1])
        endIdx = math.min(highMidBand[2], #self.FFTData)
        for i = startIdx, endIdx do
            vocalEnergy = vocalEnergy + (self.FFTData[i] or 0) * 0.7
            vocalCount = vocalCount + 0.7
        end
    end

    vocalEnergy = vocalCount > 0 and (vocalEnergy / vocalCount) or 0

    -- Calculate energy in bass/instrumental frequencies
    local instrumentalEnergy = 0
    local instrumentalCount = 0

    -- Sub-bass (kicks, deep bass)
    if subBassBand then
        startIdx = math.max(1, subBassBand[1])
        endIdx = math.min(subBassBand[2], #self.FFTData)
        for i = startIdx, endIdx do
            instrumentalEnergy = instrumentalEnergy + (self.FFTData[i] or 0)
            instrumentalCount = instrumentalCount + 1
        end
    end

    -- Bass range
    startIdx = math.max(1, bassBand[1])
    endIdx = math.min(bassBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        instrumentalEnergy = instrumentalEnergy + (self.FFTData[i] or 0)
        instrumentalCount = instrumentalCount + 1
    end

    instrumentalEnergy = instrumentalCount > 0 and (instrumentalEnergy / instrumentalCount) or 0

    -- Store in history for adaptive thresholds
    table.insert(tracker.vocalEnergyHistory, vocalEnergy)
    table.insert(tracker.bassEnergyHistory, instrumentalEnergy)

    if #tracker.vocalEnergyHistory > 100 then
        table.remove(tracker.vocalEnergyHistory, 1)
    end
    if #tracker.bassEnergyHistory > 100 then
        table.remove(tracker.bassEnergyHistory, 1)
    end

    -- Calibration phase: learn the song's characteristics
    tracker.calibrationSamples = tracker.calibrationSamples + 1

    if tracker.calibrationSamples < 50 then
        -- Still calibrating, update max values
        tracker.maxVocalEnergy = math.max(tracker.maxVocalEnergy, vocalEnergy)
        tracker.maxBassEnergy = math.max(tracker.maxBassEnergy, instrumentalEnergy)

        -- Don't return a value during early calibration
        self.VocalEnergySmooth = 0
        return false, 0
    end

    -- Calculate adaptive max values (with decay)
    tracker.maxVocalEnergy = math.max(tracker.maxVocalEnergy * 0.995, vocalEnergy)
    tracker.maxBassEnergy = math.max(tracker.maxBassEnergy * 0.995, instrumentalEnergy)

    -- Normalize energies
    local normalizedVocal = tracker.maxVocalEnergy > 0.001 and (vocalEnergy / tracker.maxVocalEnergy) or 0
    local normalizedBass = tracker.maxBassEnergy > 0.001 and (instrumentalEnergy / tracker.maxBassEnergy) or 0

    -- Calculate vocal presence using multiple methods
    local vocalPresence = 0

    -- Method 1: Energy ratio (vocal energy vs bass energy)
    local totalEnergy = normalizedVocal + normalizedBass + 0.001
    local energyRatio = normalizedVocal / totalEnergy

    -- Method 2: Absolute vocal energy (catches a cappella sections)
    local absoluteVocal = normalizedVocal

    -- Method 3: Spectral balance (vocals create a "dip" in bass when present)
    local spectralBalance = normalizedVocal > normalizedBass and 1 or (normalizedVocal / (normalizedBass + 0.001))
    spectralBalance = math.Clamp(spectralBalance, 0, 1)

    -- Combine methods with weights
    vocalPresence = (energyRatio * 0.4) + (absoluteVocal * 0.4) + (spectralBalance * 0.2)
    vocalPresence = math.Clamp(vocalPresence, 0, 1)

    -- Apply smoothing to reduce jitter
    tracker.vocalEnergySmooth = Lerp(0.15, tracker.vocalEnergySmooth, vocalEnergy)
    tracker.vocalPresenceSmooth = Lerp(0.2, tracker.vocalPresenceSmooth, vocalPresence)

    -- Store for external access
    self.VocalEnergySmooth = tracker.vocalPresenceSmooth

    -- Detect vocal onset (for triggering effects)
    local isOnset = false
    local onsetIntensity = 0

    if currentTime - tracker.lastVocalTime > 0.1 then
        -- Calculate recent average
        local recentAvg = 0
        local recentCount = 0
        local historySize = #tracker.vocalEnergyHistory

        for i = math.max(1, historySize - 20), historySize do
            recentAvg = recentAvg + (tracker.vocalEnergyHistory[i] or 0)
            recentCount = recentCount + 1
        end
        recentAvg = recentCount > 0 and (recentAvg / recentCount) or 0

        -- Onset when energy suddenly increases above recent average
        local onsetThreshold = recentAvg * 1.4
        if vocalEnergy > onsetThreshold and vocalEnergy > 0.15 and tracker.vocalPresenceSmooth > 0.3 then
            isOnset = true
            onsetIntensity = math.min(1, (vocalEnergy - onsetThreshold) / (onsetThreshold + 0.001))
            tracker.lastVocalTime = currentTime
        end
    end

    -- Return onset detection (for backwards compatibility) and smoothed vocal presence
    return isOnset, tracker.vocalPresenceSmooth
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

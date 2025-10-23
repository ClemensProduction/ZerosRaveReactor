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
    --self:OnBassUpdate(self.BassIntensity)
    --self:OnTrebleUpdate(self.TrebleIntensity)
    --self:OnVolumeUpdate(self.VisualIntensity)
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
        print("Bassline Groove:", grooveType, "Confidence:", grooveConfidence)
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
    Detect vocal presence and onsets with broader coverage for 90% of songs
    - Broadened bands: Formants 1-12 (0-4130Hz) for low/high fundamentals (male bass to soprano)
    - Harmonics 13-20 (4130-6880Hz), sibilance 21-30 (6880-10320Hz), presence/air 31-40 (10320-13760Hz) for breath/highs
    - Added vocal-specific flux to catch onsets without bass confusion
    - Enhanced features: Harmonic ratio (peaks vs noise), rolloff proxy via high-band energy
    - Adaptive: Calibration learns song's mid-range baseline, rejects synth false positives via tonality+consistency
    - Onset: Requires vocal flux + sustained presence + low bass correlation
    @return boolean, number: Onset detected, smoothed presence (0-1)
]]
function ENT:DetectVocalOnset()
    local currentTime = CurTime()

    -- Initialize tracker if needed
    if not self.VocalTracker then
        self.VocalTracker = {
            -- Energy histories
            vocalEnergyHistory = {},
            instrumentalEnergyHistory = {},
            centroidHistory = {},
            flatnessHistory = {},
            harmonicRatioHistory = {},  -- New: For harmonic structure

            -- Smoothed values
            vocalPresenceSmooth = 0,
            vocalEnergySmooth = 0,
            centroidSmooth = 0,
            flatnessSmooth = 0,
            harmonicRatioSmooth = 0,

            -- Baselines (adaptive max/avg)
            vocalBaselineMax = 0.01,
            vocalBaselineAvg = 0.01,
            instrumentalBaselineMax = 0.01,
            instrumentalBaselineAvg = 0.01,

            -- Detection state
            lastVocalTime = 0,
            calibrationSamples = 0,
            historySize = 120,  -- ~3-4 seconds
        }
    end

    local tracker = self.VocalTracker

    if not self.FFTData or #self.FFTData == 0 then
        return false, 0
    end

    -- Broadened bands for wider voice coverage (~344Hz/bin)
    local formantBand = {1, 12}    -- 0-4130Hz: Covers bass (75Hz) to soprano (1100Hz) fundamentals + formants
    local harmonicBand = {13, 20}  -- 4130-6880Hz: Harmonics for most genres
    local sibilanceBand = {21, 30} -- 6880-10320Hz: Sibilants/consonants
    local presenceBand = {31, 40}  -- 10320-13760Hz: Air/breath for natural vocals
    local bassBand = self.FrequencyBands["Bass"] or {1, 3}       -- Low instruments
    local subBassBand = self.FrequencyBands["SubBass"] or {1, 1} -- Deep bass

    -- Calculate weighted vocal energy (higher weight on formants, include presence)
    local vocalEnergy = 0
    local vocalCount = 0
    local fftSum = 0  -- For features
    local fftGeo = 1
    local fftBins = 0
    local peakCount = 0  -- For harmonic ratio (simple peak detector)
    local noiseEnergy = 0

    -- Formants (high weight)
    local startIdx = math.max(1, formantBand[1])
    local endIdx = math.min(formantBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        vocalEnergy = vocalEnergy + val * 1.0
        vocalCount = vocalCount + 1.0
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end

    -- Harmonics (medium weight)
    startIdx = math.max(1, harmonicBand[1])
    endIdx = math.min(harmonicBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        vocalEnergy = vocalEnergy + val * 0.7
        vocalCount = vocalCount + 0.7
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end

    -- Sibilance (low weight)
    startIdx = math.max(1, sibilanceBand[1])
    endIdx = math.min(sibilanceBand[2], #self.FFTData)
    local sibilanceEnergy = 0
    local sibilanceCount = 0
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        sibilanceEnergy = sibilanceEnergy + val
        sibilanceCount = sibilanceCount + 1
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
        if i > 1 and i < #self.FFTData and val > (self.FFTData[i-1] or 0) and val > (self.FFTData[i+1] or 0) then
            peakCount = peakCount + 1
        else
            noiseEnergy = noiseEnergy + val
        end
    end
    sibilanceEnergy = sibilanceCount > 0 and (sibilanceEnergy / sibilanceCount) or 0

    -- Presence/air (boost for natural vocals, low weight)
    startIdx = math.max(1, presenceBand[1])
    endIdx = math.min(presenceBand[2], #self.FFTData)
    local presenceEnergy = 0
    local presenceCount = 0
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        presenceEnergy = presenceEnergy + val
        presenceCount = presenceCount + 1
        fftSum = fftSum + val
        fftGeo = fftGeo * (val + 1e-6)
        fftBins = fftBins + 1
    end
    presenceEnergy = presenceCount > 0 and (presenceEnergy / presenceCount) or 0

    vocalEnergy = vocalCount > 0 and (vocalEnergy / vocalCount) or 0

    -- Instrumental energy
    local instrumentalEnergy = 0
    local instrumentalCount = 0
    startIdx = math.max(1, subBassBand[1])
    endIdx = math.min(subBassBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        instrumentalEnergy = instrumentalEnergy + val
        instrumentalCount = instrumentalCount + 1
    end
    startIdx = math.max(1, bassBand[1])
    endIdx = math.min(bassBand[2], #self.FFTData)
    for i = startIdx, endIdx do
        local val = self.FFTData[i] or 0
        instrumentalEnergy = instrumentalEnergy + val
        instrumentalCount = instrumentalCount + 1
    end
    instrumentalEnergy = instrumentalCount > 0 and (instrumentalEnergy / instrumentalCount) or 0

    -- Spectral features
    local spectralCentroid = 0
    if fftSum > 0 then
        local weightedSum = 0
        for i = 1, #self.FFTData do
            weightedSum = weightedSum + (self.FFTData[i] or 0) * i
        end
        spectralCentroid = weightedSum / fftSum  -- Higher for vocals
    end

    local spectralFlatness = 0
    if fftBins > 0 then
        local arithMean = fftSum / fftBins
        local geoMean = (fftGeo ^ (1 / fftBins))
        spectralFlatness = geoMean / (arithMean + 1e-6)  -- Lower for tonal vocals
    end

    -- New: Simple harmonic ratio (peaks vs noise, higher for voiced sounds)
    local harmonicRatio = (peakCount > 0 and fftBins > 0) and (peakCount / fftBins) * (fftSum / (noiseEnergy + 1e-6)) or 0
    harmonicRatio = math.Clamp(harmonicRatio, 0, 1)

    -- Store histories
    table.insert(tracker.vocalEnergyHistory, vocalEnergy)
    table.insert(tracker.instrumentalEnergyHistory, instrumentalEnergy)
    table.insert(tracker.centroidHistory, spectralCentroid)
    table.insert(tracker.flatnessHistory, spectralFlatness)
    table.insert(tracker.harmonicRatioHistory, harmonicRatio)

    if #tracker.vocalEnergyHistory > tracker.historySize then
        table.remove(tracker.vocalEnergyHistory, 1)
        table.remove(tracker.instrumentalEnergyHistory, 1)
        table.remove(tracker.centroidHistory, 1)
        table.remove(tracker.flatnessHistory, 1)
        table.remove(tracker.harmonicRatioHistory, 1)
    end

    -- Calibration (extend to 100 samples for better song adaptation)
    tracker.calibrationSamples = tracker.calibrationSamples + 1
    if tracker.calibrationSamples < 100 then
        return false, 0
    end

    -- Update max baselines with slower decay
    tracker.vocalBaselineMax = math.max(tracker.vocalBaselineMax * 0.995, vocalEnergy)
    tracker.instrumentalBaselineMax = math.max(tracker.instrumentalBaselineMax * 0.995, instrumentalEnergy)

    -- Trimmed avg for robustness
    local function getTrimmedAvg(history)
        local sorted = table.Copy(history)
        table.sort(sorted)
        local trim = math.floor(#sorted * 0.1)
        local sum = 0
        for i = trim + 1, #sorted - trim do
            sum = sum + sorted[i]
        end
        return (#sorted - 2 * trim > 0) and (sum / (#sorted - 2 * trim)) or 0.01
    end

    tracker.vocalBaselineAvg = getTrimmedAvg(tracker.vocalEnergyHistory)
    tracker.instrumentalBaselineAvg = getTrimmedAvg(tracker.instrumentalEnergyHistory)

    -- Normalize
    local normVocal = tracker.vocalBaselineMax > 0.001 and (vocalEnergy / tracker.vocalBaselineMax) or 0
    local normInstrumental = tracker.instrumentalBaselineMax > 0.001 and (instrumentalEnergy / tracker.instrumentalBaselineMax) or 0
    local normCentroid = math.Clamp((spectralCentroid - 4) / 25, 0, 1)  -- Adjusted for broader bands (vocals ~4-30)
    local normFlatness = 1 - math.Clamp(spectralFlatness, 0, 1)  -- High for tonal
    local normSibilance = math.Clamp(sibilanceEnergy / (tracker.vocalBaselineAvg + 1e-6), 0, 1)
    local normPresence = math.Clamp(presenceEnergy / (tracker.vocalBaselineAvg * 0.5 + 1e-6), 0, 1)  -- Lower expectation for highs
    local normHarmonic = math.Clamp(harmonicRatio, 0, 1)

    -- Vocal presence (weighted, added harmonic+presence for better distinction)
    local energyRatio = normVocal / (normVocal + normInstrumental + 0.001)
    local absoluteVocal = normVocal
    local spectralBalance = (normVocal > normInstrumental * 0.7) and 1 or (normVocal / (normInstrumental + 0.001))  -- Loosened for quiet vocals
    local tonalityBoost = normFlatness * 0.4 + normCentroid * 0.3 + normHarmonic * 0.3
    local highFreqBoost = (normSibilance * 0.5 + normPresence * 0.5) > 0.25 and 0.2 or 0

    local vocalPresence = (energyRatio * 0.25) + (absoluteVocal * 0.25) + (spectralBalance * 0.2) + (tonalityBoost * 0.2) + highFreqBoost
    vocalPresence = math.Clamp(vocalPresence, 0, 1)

    -- Smoothing
    tracker.vocalPresenceSmooth = Lerp(FrameTime() * 1.2, tracker.vocalPresenceSmooth, vocalPresence)  -- Slightly slower
    tracker.vocalEnergySmooth = Lerp(FrameTime() * 4, tracker.vocalEnergySmooth, vocalEnergy)
    tracker.centroidSmooth = Lerp(FrameTime() * 3, tracker.centroidSmooth, normCentroid)
    tracker.flatnessSmooth = Lerp(FrameTime() * 3, tracker.flatnessSmooth, normFlatness)
    tracker.harmonicRatioSmooth = Lerp(FrameTime() * 3, tracker.harmonicRatioSmooth, normHarmonic)

    -- Store
    self.vocalPresenceSmooth = tracker.vocalPresenceSmooth
    self.VocalEnergySmooth = tracker.vocalEnergySmooth

    -- Onset detection (add vocal-specific flux, check bass correlation)
    local isOnset = false
    if currentTime - tracker.lastVocalTime > 0.1 then
        local recentAvgVocal = getTrimmedAvg({unpack(tracker.vocalEnergyHistory, #tracker.vocalEnergyHistory - 20)})
        local onsetThreshold = recentAvgVocal * (0.9 + (tracker.vocalBaselineAvg * 0.1))  -- Loosened for variety

        -- Vocal flux (positive change in vocal bands only)
        local vocalFlux = 0
        if self.PrevFFTData then
            for i = formantBand[1], presenceBand[2] do
                local curr = self.FFTData[i] or 0
                local prev = self.PrevFFTData[i] or 0
                vocalFlux = vocalFlux + math.max(0, curr - prev)
            end
            vocalFlux = vocalFlux / (presenceBand[2] - formantBand[1] + 1)
        end

        -- Bass correlation (high if vocal spike matches bass)
        local bassFlux = self:GetFrequencyIntensity("Bass") - (self.PrevFFTData and self:GetFrequencyIntensity("Bass") or 0)  -- Approx
        local bassCorrelation = math.abs(bassFlux) > 0.15 and 1 or 0

		local check_energy = vocalEnergy > onsetThreshold
		local check_presence = vocalPresence > 0.3
		local check_flat = tracker.flatnessSmooth > 0.25
		local check_harmonic = tracker.harmonicRatioSmooth > 0.3
		local check_flux = vocalFlux > 0.01
		local check_bass = bassCorrelation < 0.5

		/*
		print("vocalEnergy",":",tostring(vocalEnergy))
		print("onsetThreshold",":",tostring(onsetThreshold))
		print("vocalPresence",":",tostring(vocalPresence))
		print("flatnessSmooth",":",tostring(tracker.flatnessSmooth))
		print("harmonicRatioSmooth",":",tostring(tracker.harmonicRatioSmooth))
		print("vocalFlux",":",tostring(vocalFlux))
		print("bassCorrelation",":",tostring(bassCorrelation))

		print("-----")

		print("check_energy",":",tostring(check_energy))
		print("check_presence",":",tostring(check_presence))
		print("check_flat",":",tostring(check_flat))
		print("check_harmonic",":",tostring(check_harmonic))
		print("check_flux",":",tostring(check_flux))
		print("check_bass",":",tostring(check_bass))
		*/

		local check_result = check_energy and check_presence and check_flat and check_harmonic and check_flux and check_bass

		-- Conditions: Energy spike, high presence/tonality/harmonic, good flux, low bass corr
        if check_result then

            -- Sustain check: 3/5 recent frames high
            local sustainCount = 0
            for i = #tracker.vocalEnergyHistory - 4, #tracker.vocalEnergyHistory do  -- Last 5
                if tracker.vocalEnergyHistory[i] > onsetThreshold * 0.8 then
                    sustainCount = sustainCount + 1
                end
            end

            if sustainCount >= 3 then
                isOnset = true
                tracker.lastVocalTime = currentTime
            end
        end
    end

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

    if consistency > 0.7 then

		-- Determine pattern type based on tempo
		-- TODO Different FPS can cause issues, always check what the clients fps is
		local fps = 1 / FrameTime()
		local bpm = fps / avgInterval-- 140 * self.BassIntensity --30 / avgInterval
		print(bpm)
		local patternType = "none"

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

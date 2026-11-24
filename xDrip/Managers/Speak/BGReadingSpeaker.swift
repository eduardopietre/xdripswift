import Foundation
import AVFoundation
import AudioToolbox
import os
import Speech

class BGReadingSpeaker:NSObject {
    
    // MARK: - public properties
    
    // MARK: - private properties
    
    /// reference to coreDataManager
    private var coreDataManager:CoreDataManager
    
    /// a BgReadingsAccessor
    private var bgReadingsAccessor:BgReadingsAccessor
    
    /// audioplayer used by app
    ///
    /// is used to verify if app happens to be playing a sound, in which case new readings shouldn't be spoken
    private var sharedSoundPlayer:SoundPlayer
    
    /// timestamp of last spoken reading, initially set to 1 jan 1970
    private var timeStampLastSpokenReading:Date
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper:KeyValueObserverTimeKeeper = KeyValueObserverTimeKeeper()
    
    /// speech synthesizer object
    /// this must be created here instead of locally in the say() function for it to work correctly in iOS16
    /// https://developer.apple.com/forums/thread/714984
    private let syn = AVSpeechSynthesizer.init()
    
    // MARK: - initializer
    
    /// init is private, to avoid creation
    init(sharedSoundPlayer:SoundPlayer, coreDataManager:CoreDataManager) {
        
        // initialize non optional private properties
        self.sharedSoundPlayer = sharedSoundPlayer
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        // initialize timeStampLastSpokenReading
        timeStampLastSpokenReading = Date(timeIntervalSince1970: 0)
        
        // call super.init
        super.init()
        
        // set languageCode in Texts_SpeakReading to value stored in defaults
        Texts_SpeakReading.setLanguageCode(code: UserDefaults.standard.speakReadingLanguageCode)
        
        // changing speakerLanguage code requires action
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.speakReadingLanguageCode.rawValue, options: .new, context: nil)

    }
    
    // MARK: - public functions
    
    /// will speak the latest reading in the iPhone's language
    ///
    /// conditions:
    ///     - speakReadings is on
    ///     - the current local time is within the daily schedule, if scheduling is enabled
    ///     - no other sound is playing (via sharedAudioPlayer)
    ///     - there' s a recent reading less than 4.5 minutes old
    ///     - time since last spoken reading > interval defined by user (UserDefaults.standard.speakInterval)
    ///     - lastConnectionStatusChangeTimeStamp : when was the last transmitter dis/reconnect
    public func speakNewReading(lastConnectionStatusChangeTimeStamp: Date) {
        
        // Shortcuts control only the master switch. The optional schedule is a separate gate
        // for new announcements and does not interrupt speech already in progress.
        if !UserDefaults.standard.shouldSpeakReadings() {
            return
        }
        
        // if app shared soundPlayer is playing, then don't say the text
        if sharedSoundPlayer.isPlaying() {
            return
        }
        
        // get latest reading, ignore sensor, rawdata, timestamp - only 1
        let lastReadings = bgReadingsAccessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 4.0)

        // if there's no readings, then no further processing
        if lastReadings.count == 0 {
            return
        }
        
        // if an interval is defined, and if time since last spoken reading is less than interval, then don't speak
        // substract 10 seconds, because user will probably select a multiple of 5, and also readings usually arrive every 5 minutes
        // example user selects 10 minutes interval, next reading will arrive in exactly 10 minutes, time interval to be checked will be 590 seconds
        if Int(Date().timeIntervalSince(timeStampLastSpokenReading)) < (UserDefaults.standard.speakInterval * 60 - 10) {
            return
        }
        
        // check if timeStampLastSpokenReading is at least minimiumTimeBetweenTwoReadingsInMinutes earlier than now (or it's at least minimiumTimeBetweenTwoReadingsInMinutes minutes ago that reading was spoken) - otherwise don't speak the reading
        // exception : there's been a disconnect/reconnect after the last spoken reading
        if (abs(timeStampLastSpokenReading.timeIntervalSince(Date())) < ConstantsSpeakReading.minimiumTimeBetweenTwoReadingsInMinutes * 60.0 && lastConnectionStatusChangeTimeStamp.timeIntervalSince(timeStampLastSpokenReading) < 0) {
            
            return
            
        }
        
        // assign bgReadingToSpeak
        let bgReadingToSpeak = lastReadings[0]
        
        // if reading older dan 4.5 minutes, then no further processing
        if Date().timeIntervalSince(bgReadingToSpeak.timeStamp) > 4.5 * 60 {
            return
        }
        
        say(text: Self.readingText(lastReadings), language: Texts_SpeakReading.languageCode)
        timeStampLastSpokenReading = bgReadingToSpeak.timeStamp
    }

    /// Use the same wording for automatic readings and the settings preview.
    private static func readingText(_ readings: [BgReading]) -> String {
        let reading = readings[0]
        return speechText(
            glucose: reading.unitizedString(unitIsMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl),
            trend: reading.slopeName,
            delta: reading.unitizedDeltaString(previousBgReading: readings.count > 1 ? readings[1] : nil, showUnit: false, highGranularity: true, mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
        )
    }

    /// A manual preview uses readings up to 11 minutes old and does not change the automatic schedule or interval.
    static func previewText(coreDataManager: CoreDataManager?) -> String {
        if let coreDataManager {
            let readings = BgReadingsAccessor(coreDataManager: coreDataManager).get2LatestBgReadings(minimumTimeIntervalInMinutes: 4.0)
            if let reading = readings.first, Date().timeIntervalSince(reading.timeStamp) <= 11 * 60 {
                return readingText(readings)
            }
        }
        return speechText(glucose: UserDefaults.standard.bloodGlucoseUnitIsMgDl ? "100" : "5.6", trend: "Flat", delta: "0")
    }

    static func speechText(glucose: String, trend: String, delta: String) -> String {
        // start creating the text that needs to be spoken
        var currentBgReadingOutput = UserDefaults.standard.speakIntroduction ? Texts_SpeakReading.currentGlucose + " ,, " : ""
        
        //Glucose
        // create reading value
        var currentBgReadingFormatted = glucose
        // copied from Spike
        if !UserDefaults.standard.bloodGlucoseUnitIsMgDl {
            currentBgReadingFormatted = assertFractionalDigits(number: currentBgReadingFormatted)
        }
        currentBgReadingFormatted = formatLocaleSpecific(number: currentBgReadingFormatted, languageCode: Texts_SpeakReading.languageCode)
        if (currentBgReadingFormatted == "HIGH") {
            currentBgReadingFormatted = ". " + Texts_SpeakReading.high;
        } else if (currentBgReadingFormatted == "LOW") {
            currentBgReadingFormatted = ". " + Texts_SpeakReading.low;
        }
        currentBgReadingOutput += currentBgReadingFormatted + ". "
        
        // Trend
        // if trend needs to be spoken, then compose trend text
        if UserDefaults.standard.speakTrend {

            //add trend to text (slope)
            currentBgReadingOutput += Texts_SpeakReading.currentTrend + " " + searchTranslationForCurrentTrend(currentTrend: trend) + ". ";
            
        }
        
        // Delta
        // if delta needs to be spoken then compose delta
        if UserDefaults.standard.speakDelta {
            
            var currentDelta = delta

            //Format current delta in case of anomalies
            if currentDelta == "ERR" || currentDelta == "???"{
                currentDelta = Texts_SpeakReading.deltanoncomputable
            }
            
            if (currentDelta == "0.0" || currentDelta == "+0" || currentDelta == "-0") {
                currentDelta = "0"
            }
            
            currentDelta = formatLocaleSpecific(number: currentDelta, languageCode: Texts_SpeakReading.languageCode)
            
            currentBgReadingOutput += Texts_SpeakReading.currentDelta + " " + currentDelta + "."
            
        }
        
        return currentBgReadingOutput
    }

    // MARK: - private functions

    /// will speak the text, using language code for pronunciation
    private func say(text:String, language:String?) {
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.51
        utterance.pitchMultiplier = 1
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        syn.speak(utterance)

    }

    /// copied from Spike -
    /// if number is a Double value, and if it has no "." then a "." is added - otherwise returns number
    private static func assertFractionalDigits(number:String) -> String {
        
        let newNumber = number.replacingOccurrences(of: " ", with: "")
        
        if Double(newNumber) != nil {
            if !number.contains(find: ".") {
               return number + ".0"
            }
        }
        
        return number
        
    }
    
    /// copied from Spike
    /// - parameters:
    ///     - languageCode : must be format like en-EN
    private static func formatLocaleSpecific(number:String, languageCode:String?) -> String {
        
        let newNumber = number.replacingOccurrences(of: " ", with: "")
        
        if Double(newNumber) != nil, let languageCode = languageCode {
            if languageCode.uppercased().startsWith("DE") {
                return number.replacingOccurrences(of: ".", with: ",")
            }
        }
        
        return number
    }
    
    /// translates currentTrend string to local string
    ///
    /// example if currentTrend = trenddoubledown, then for en-EN, return dramatically downward
    private static func searchTranslationForCurrentTrend(currentTrend:String) -> String {
        
        if (currentTrend == "NONE" || currentTrend == "NON COMPUTABLE") {
            return Texts_SpeakReading.trendnoncomputable
        }
        else if (currentTrend == "DoubleDown") {
            return Texts_SpeakReading.trenddoubledown
        }
        else if (currentTrend == "SingleDown") {
            return Texts_SpeakReading.trendsingledown
        }
        else if (currentTrend == "FortyFiveDown") {
            return Texts_SpeakReading.trendfortyfivedown
        }
        else if (currentTrend == "Flat") {
            return Texts_SpeakReading.trendflat
        }
        else if (currentTrend == "FortyFiveUp") {
            return Texts_SpeakReading.trendfortyfiveup
        }
        else if (currentTrend == "SingleUp") {
            return Texts_SpeakReading.trendsingleup
        }
        else if (currentTrend == "DoubleUp") {
            return Texts_SpeakReading.trenddoubleup
        }
        return currentTrend
    }
    
    // MARK:- observe function
    
    /// when user changes Speak Reading language code, action to do
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let keyPath = keyPath {
            
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                
                switch keyPathEnum {
                    
                case UserDefaults.Key.speakReadingLanguageCode :
                    
                    // change by user, should not be done within 200 ms
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        // UserDefaults.standard.speakReadingLanguageCode shouldn't be nil normally, if it is would be a coding error, however need to check anyway so assign default if nil
                        Texts_SpeakReading.setLanguageCode(code: UserDefaults.standard.speakReadingLanguageCode)
                        
                    }
                    
                default:
                    break
                }
            }
        }
    }
    

}

/// The audio session options used while a reading is spoken and afterwards.
///
/// Today other audio is never lowered while a reading is spoken (#741).
enum SpeakReadingAudioPolicy {
    /// - parameters:
    ///     - whileSpeaking: true while a reading is being spoken
    ///     - duckOtherAudio: the user's setting to lower other audio while speaking, off by default
    static func categoryOptions(whileSpeaking: Bool, duckOtherAudio: Bool) -> AVAudioSession.CategoryOptions {
        .mixWithOthers
    }

    /// What to do with the audio session when a reading that lowered other audio has been spoken.
    enum AfterSpeakingAction: Equatable {
        /// another reading that lowers other audio is still being spoken
        case nothing
        /// only remove the option that lowers other audio
        case restoreOptions
        /// deactivate the session so other audio returns to full volume, then activate it again
        /// with the options the app always uses
        case deactivateAndReactivate
    }

    /// - parameters:
    ///     - duckedUtterancesLeft: readings that lowered other audio and are still being spoken
    ///     - appSoundIsPlaying: whether the app itself is playing a sound, such as an alarm
    /// Whether a reading lowers other audio.
    /// - parameters:
    ///     - optionIsOn: the user's setting to lower other audio while speaking
    ///     - keepAliveAudioMayPlay: see `keepAliveAudioMayPlay(isMaster:keepAliveType:)`
    static func lowersOtherAudio(optionIsOn: Bool, keepAliveAudioMayPlay: Bool) -> Bool {
        optionIsOn
    }

    /// Whether the follower keep-alive may be playing silent audio: in follower mode, with a keep-alive
    /// type that plays audio. Heartbeat keeps the app alive without audio.
    static func keepAliveAudioMayPlay(isMaster: Bool, keepAliveType: FollowerBackgroundKeepAliveType) -> Bool {
        !isMaster && [.normal, .aggressive, .continuous].contains(keepAliveType)
    }

    /// The readings that lowered other audio and are still being spoken, when a new one starts.
    static func duckedReadingsStillSpoken(_ count: Int, synthesizerIsSpeaking: Bool) -> Int {
        count
    }

    static func afterSpeaking(duckedUtterancesLeft: Int, appSoundIsPlaying: Bool) -> AfterSpeakingAction {
        .restoreOptions
    }
}

import CoreAudio
import Foundation

/// Mirrors the constants declared in AudioDriver/Plugin/PlugInTypes.h. Kept in sync by hand since
/// this is a pure-Swift client talking to the driver only through standard CoreAudio Device I/O
/// and property calls — there is no shared C header between the driver process (coreaudiod) and
/// this tool's process.
enum JarvisCallAudio {
    static let bundleID = "com.jarvis.callbridge.audio"

    enum Capture {
        static let deviceUID = "com.jarvis.callbridge.audio.capture"
        static let name = "Jarvis Call Capture"
    }

    enum Inject {
        static let deviceUID = "com.jarvis.callbridge.audio.inject"
        static let name = "Jarvis Call Inject"
    }

    enum Tap {
        static let deviceUID = "com.jarvis.callbridge.audio.tap"
        static let name = "Jarvis Call Tap"
    }

    enum Speaker {
        static let deviceUID = "com.jarvis.callbridge.audio.speaker"
        static let name = "Jarvis Speaker"
    }

    static let sampleRate: Double = 48000
    static let channelCount: Int = 2

    /// Must match PlugInTypes.h's kJarvisDevicePropertyActive ('Ract').
    static let propertyActive: AudioObjectPropertySelector = fourCharCode("Ract")
    /// Must match PlugInTypes.h's kJarvisDevicePropertyClearBuffers ('Rclr').
    static let propertyClearBuffers: AudioObjectPropertySelector = fourCharCode("Rclr")
    /// Must match PlugInTypes.h's kJarvisDevicePropertyPCMDiagnostics ('Rpcm') — Phase 3
    /// CHECKPOINT 2 RX investigation, read-only.
    static let propertyPCMDiagnostics: AudioObjectPropertySelector = fourCharCode("Rpcm")
}

func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars {
        result = (result << 8) + FourCharCode(scalar.value)
    }
    return result
}

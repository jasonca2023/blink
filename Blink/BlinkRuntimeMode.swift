import Foundation

enum BlinkRuntimeMode {
    static var isBlinkBundle: Bool {
        Bundle.main.bundleIdentifier == "com.blink.blink"
    }

    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return isBlinkBundle
        #endif
    }

    static var stableApplicationPath: String {
        "/Applications/Blink.app"
    }
}

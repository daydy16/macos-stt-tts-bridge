#!/usr/bin/env swift

// STTBridge Server CLI
// Startet nur das Backend ohne UI

import Foundation
import Speech

// Minimal Config (kopiere von Config.swift)
struct CLIConfig {
    let bindHost = "127.0.0.1"
    let port = 8787
    let authToken: String? = nil
    let defaultLang = "de-DE"
    let offlineOnly = false
}

print("🚀 STTBridge Server (Headless)")
print("================================")

// Request Speech permissions
let semaphore = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { status in
    switch status {
    case .authorized:
        print("✓ Speech Recognition authorized")
    case .denied:
        print("✗ Speech Recognition denied - app won't work!")
    case .restricted:
        print("✗ Speech Recognition restricted")
    case .notDetermined:
        print("⚠ Speech Recognition not determined")
    @unknown default:
        print("⚠ Unknown authorization status")
    }
    semaphore.signal()
}
semaphore.wait()

print("\n📡 Starting server...")
print("   Host: 127.0.0.1")
print("   Port: 8787")
print("\n✓ Server running!")
print("  → http://127.0.0.1:8787")
print("  → Press Ctrl+C to stop\n")

// Keep running
RunLoop.main.run()

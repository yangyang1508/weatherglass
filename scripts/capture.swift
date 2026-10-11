// Captures the windows of one app and nothing else, so a recording can never show the rest of your screen.
//
//   swiftc -O scripts/capture.swift -o .build/capture
//   .build/capture shot  <pid> <file.png>
//   .build/capture video <pid> <seconds> <file.mov>
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[2]) else {
    fail("usage: capture shot <pid> <file.png> | capture video <pid> <seconds> <file.mov>")
}

func filter(for pid: Int32) async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let app = content.applications.first(where: { $0.processID == pid }) else { fail("no windows for pid \(pid)") }
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        fail("no display")
    }
    return SCContentFilter(display: display, including: [app], exceptingWindows: [])
}

func configuration(for f: SCContentFilter) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    c.width = Int(f.contentRect.width * CGFloat(f.pointPixelScale))
    c.height = Int(f.contentRect.height * CGFloat(f.pointPixelScale))
    c.showsCursor = false
    c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    return c
}

final class Finish: NSObject, SCRecordingOutputDelegate {
    var done: CheckedContinuation<Void, Never>?
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        done?.resume()
        done = nil
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        fail("recording failed: \(error.localizedDescription)")
    }
}

do {
    let f = try await filter(for: pid)
    switch args[1] {
    case "shot":
        let image: CGImage = try await withCheckedThrowingContinuation { c in
            SCScreenshotManager.captureImage(contentFilter: f, configuration: configuration(for: f)) { image, error in
                if let image { c.resume(returning: image) } else { c.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { fail("cannot write") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    case "video":
        guard args.count >= 5, let seconds = Double(args[3]) else { fail("usage: capture video <pid> <seconds> <file.mov>") }
        let url = URL(fileURLWithPath: args[4])
        try? FileManager.default.removeItem(at: url)
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        let finish = Finish()
        let output = SCRecordingOutput(configuration: rc, delegate: finish)
        let stream = SCStream(filter: f, configuration: configuration(for: f), delegate: nil)
        try stream.addRecordingOutput(output)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await withCheckedContinuation { c in
            finish.done = c
            stream.stopCapture { _ in }
        }
    default:
        fail("unknown mode \(args[1])")
    }
} catch {
    fail("capture failed: \(error.localizedDescription)")
}

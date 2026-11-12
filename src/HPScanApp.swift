// HP Scan — tiny SwiftUI front end for the `hpscan` CLI (HPLIP hpaio backend).
// Build: swiftc -parse-as-library -O HPScanApp.swift -o "HP Scan"
import AppKit
import SwiftUI

let hpscanPath = "/Library/Printers/HPLIP/bin/hpscan"

@main
struct HPScanApp: App {
    var body: some Scene {
        WindowGroup("HP Scan") {
            ScanView().frame(width: 380)
        }
        .windowResizability(.contentSize)
    }
}

struct ScanView: View {
    @AppStorage("mode") private var mode = "Color"
    @AppStorage("dpi") private var dpi = 300
    @AppStorage("format") private var format = "pdf"
    @State private var busy = false
    @State private var status = "Put the page face down on the glass."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Mode", selection: $mode) {
                    Text("Color").tag("Color")
                    Text("Grayscale").tag("Gray")
                    Text("Black & White").tag("Lineart")
                }
                Picker("Resolution", selection: $dpi) {
                    ForEach([75, 100, 200, 300, 600, 1200], id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Picker("Format", selection: $format) {
                    Text("PDF").tag("pdf")
                    Text("JPEG").tag("jpg")
                    Text("PNG").tag("png")
                    Text("TIFF").tag("tiff")
                }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(busy ? "Scanning…" : "Scan") { scan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
    }

    private func scan() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "Scan \(stamp).\(format)"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busy = true
        status = "Scanning at \(dpi) dpi…"
        let args = ["-m", mode, "-r", String(dpi), url.path]
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: hpscanPath)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            var message: String
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    message = "Saved \(url.lastPathComponent)"
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                } else {
                    message = out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "hpscan: ", with: "") }
                        ?? "Scan failed (\(p.terminationStatus))"
                    if p.terminationStatus == 3 { message = "Scanner not found. Is the printer on and plugged in?" }
                    if p.terminationStatus == 4 { message = "The scanner is busy or not responding. Try again in a moment." }
                }
            } catch {
                message = "Could not run \(hpscanPath): \(error.localizedDescription)"
            }
            DispatchQueue.main.async { busy = false; status = message }
        }
    }
}

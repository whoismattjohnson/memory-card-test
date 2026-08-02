//
//  TesterModel.swift
//  Memory Card Test
//
//  Copyright (C) 2026 Matt Johnson <https://whoismatt.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import SwiftUI

/// Thread-safe stop signal shared between the UI (writer) and the background
/// test engine (reader).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class TesterModel: ObservableObject {

    @Published var volumes: [CardVolume] = []
    @Published var selectedVolumeID: URL?
    @Published var includeAllVolumes = false
    @Published var mode: CardTester.Mode = .full

    @Published var isRunning = false
    @Published var phaseText = ""
    @Published var fractionComplete: Double = 0
    @Published var currentMBps: Double = 0
    @Published var processedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0

    @Published var result: CardTester.Result?

    private var cancelToken = CancelToken()

    var selectedVolume: CardVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    init() {
        rescan()
    }

    func rescan() {
        let all = includeAllVolumes
        volumes = VolumeScanner.scan(includeAll: all)
        if selectedVolumeID == nil || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id
        }
    }

    func start() {
        guard let volume = selectedVolume, !isRunning else { return }
        isRunning = true
        result = nil
        let token = CancelToken()
        cancelToken = token
        phaseText = "Preparing…"
        fractionComplete = 0
        currentMBps = 0
        processedBytes = 0
        totalBytes = 0
        let mode = self.mode
        let url = volume.url

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let tester = CardTester(
                isCancelled: { token.isCancelled() },
                onProgress: { progress in
                    Task { @MainActor [weak self] in
                        self?.apply(progress)
                    }
                }
            )
            let r = tester.run(volumeURL: url, mode: mode)
            await MainActor.run { [weak self] in
                self?.finish(with: r)
            }
        }
    }

    func cancel() {
        cancelToken.cancel()
    }

    private func apply(_ p: CardTester.Progress) {
        phaseText = p.phase.rawValue
        processedBytes = p.bytesProcessed
        totalBytes = p.totalBytes
        currentMBps = p.currentMBps
        if p.totalBytes > 0 {
            // Two phases (write, read) — map each to half the bar.
            let phaseFraction = Double(p.bytesProcessed) / Double(p.totalBytes)
            switch p.phase {
            case .writing:  fractionComplete = phaseFraction * 0.5
            case .reading:  fractionComplete = 0.5 + phaseFraction * 0.5
            case .cleaning, .done: fractionComplete = 1.0
            case .preparing: fractionComplete = 0
            }
        }
    }

    private func finish(with r: CardTester.Result) {
        result = r
        isRunning = false
        phaseText = r.succeeded ? "Done" : "Stopped"
        fractionComplete = r.succeeded ? 1.0 : fractionComplete
        rescan() // free space changed as test files were cleaned up
    }
}

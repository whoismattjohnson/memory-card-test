//
//  CardTester.swift
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

/// Core engine that writes a known pseudo-random pattern across a card's free
/// space and reads it back to verify integrity — the same idea used by F3 and
/// H2testw. Because every 4 MiB chunk is seeded by its *absolute* position in
/// the test, a fake card that silently wraps writes around its real (smaller)
/// capacity will return the wrong chunk's data on readback, and the verify pass
/// catches it — pinpointing roughly where the real capacity ends.
///
/// All I/O uses POSIX file descriptors with `F_NOCACHE` so the read test hits
/// the physical media instead of the OS unified buffer cache, and `F_FULLFSYNC`
/// so writes are flushed to the card before we report speed.
final class CardTester {

    // MARK: Types

    enum Mode {
        /// Write/verify a bounded amount (fast benchmark + sanity check).
        case quick
        /// Fill essentially all free space, then verify every byte.
        case full
    }

    enum Phase: String {
        case preparing = "Preparing"
        case writing   = "Writing"
        case reading   = "Reading & verifying"
        case cleaning  = "Cleaning up"
        case done      = "Done"
    }

    struct Progress {
        var phase: Phase
        var bytesProcessed: Int64
        var totalBytes: Int64
        var currentMBps: Double
    }

    struct Result {
        var succeeded: Bool          // did the run complete (vs. error/cancel)
        var isGenuine: Bool          // did every written byte read back correctly
        var bytesWritten: Int64
        var writeMBps: Double
        var readMBps: Double
        var claimedFreeBytes: Int64
        var verifiedGoodBytes: Int64 // bytes confirmed correct before any mismatch
        var firstBadOffset: Int64?   // byte offset of first corruption, if any
        var message: String
    }

    enum TestError: Error, CustomStringConvertible {
        case cancelled
        case notEnoughSpace
        case ioError(String)
        var description: String {
            switch self {
            case .cancelled: return "Test cancelled."
            case .notEnoughSpace: return "Not enough free space on the card to run this test."
            case .ioError(let m): return m
            }
        }
    }

    // MARK: Config

    /// 4 MiB working chunk (a multiple of 8 so we can fill it as UInt64 words).
    private let chunkSize = 4 * 1024 * 1024
    /// 1 GiB per test file in full mode (keeps the file list manageable).
    private let fileSize: Int64 = 1024 * 1024 * 1024
    /// Leave a little headroom so we never wedge the filesystem at 100% full.
    private let safetyMarginBytes: Int64 = 64 * 1024 * 1024

    private let folderName = ".MemoryCardTest-test"

    private let isCancelled: () -> Bool
    private let onProgress: (Progress) -> Void

    init(isCancelled: @escaping () -> Bool,
         onProgress: @escaping (Progress) -> Void) {
        self.isCancelled = isCancelled
        self.onProgress = onProgress
    }

    // MARK: Entry point

    /// Runs synchronously — call from a background thread.
    func run(volumeURL: URL, mode: Mode) -> Result {
        let claimedFree = freeSpace(at: volumeURL)

        // How much to test.
        let budget: Int64
        switch mode {
        case .quick:
            budget = min(claimedFree - safetyMarginBytes, 512 * 1024 * 1024)
        case .full:
            budget = claimedFree - safetyMarginBytes
        }
        guard budget >= Int64(chunkSize) else {
            return failed(claimedFree, "Not enough free space (need at least ~128 MB free).")
        }

        let testDir = volumeURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        } catch {
            return failed(claimedFree, "Could not create a test folder on the card: \(error.localizedDescription)")
        }

        var writtenFiles: [(url: URL, bytes: Int64)] = []
        defer { cleanup(files: writtenFiles.map { $0.url }, dir: testDir) }

        do {
            // ---- WRITE PHASE ----
            let writeStart = Date()
            var totalWritten: Int64 = 0
            var globalChunkIndex: UInt64 = 0
            var fileIndex = 0

            while totalWritten < budget {
                if isCancelled() { throw TestError.cancelled }
                let thisFileSize = min(fileSize, budget - totalWritten)
                let url = testDir.appendingPathComponent(String(format: "cc_%04d.dat", fileIndex))
                let written = try writeFile(at: url,
                                            size: thisFileSize,
                                            startingChunkIndex: &globalChunkIndex,
                                            totalWritten: &totalWritten,
                                            budget: budget,
                                            phaseStart: writeStart)
                writtenFiles.append((url, written))
                fileIndex += 1
                if written < thisFileSize { break } // card filled up early
            }

            let writeElapsed = max(Date().timeIntervalSince(writeStart), 0.001)
            let writeMBps = Double(totalWritten) / writeElapsed / 1_000_000.0

            // ---- READ / VERIFY PHASE ----
            let readStart = Date()
            var totalRead: Int64 = 0
            var verifyChunkIndex: UInt64 = 0
            var firstBadOffset: Int64? = nil
            var globalByteBase: Int64 = 0

            for file in writtenFiles {
                if isCancelled() { throw TestError.cancelled }
                let bad = try verifyFile(at: file.url,
                                         size: file.bytes,
                                         startingChunkIndex: &verifyChunkIndex,
                                         globalByteBase: globalByteBase,
                                         totalRead: &totalRead,
                                         grandTotal: totalWritten,
                                         phaseStart: readStart)
                if let bad = bad {
                    firstBadOffset = bad
                    break
                }
                globalByteBase += file.bytes
            }

            let readElapsed = max(Date().timeIntervalSince(readStart), 0.001)
            let readMBps = Double(totalRead) / readElapsed / 1_000_000.0

            report(.cleaning, totalWritten, totalWritten, 0)

            let genuine = (firstBadOffset == nil)
            let verifiedGood = firstBadOffset ?? totalWritten
            let msg: String
            if genuine {
                msg = "Verified \(bytes(totalWritten)) written and read back with no errors."
            } else {
                msg = "Data corruption detected after \(bytes(verifiedGood)). "
                    + "The card claims \(bytes(claimedFree)) free but did not store that much reliably — a strong sign of a fake or failing card."
            }

            return Result(succeeded: true,
                          isGenuine: genuine,
                          bytesWritten: totalWritten,
                          writeMBps: writeMBps,
                          readMBps: readMBps,
                          claimedFreeBytes: claimedFree,
                          verifiedGoodBytes: verifiedGood,
                          firstBadOffset: firstBadOffset,
                          message: msg)
        } catch let e as TestError {
            return failed(claimedFree, e.description)
        } catch {
            return failed(claimedFree, error.localizedDescription)
        }
    }

    // MARK: Write

    /// Writes `size` bytes of seeded pattern. Returns bytes actually written
    /// (may be less than `size` if the card runs out of space early).
    private func writeFile(at url: URL,
                           size: Int64,
                           startingChunkIndex globalChunkIndex: inout UInt64,
                           totalWritten: inout Int64,
                           budget: Int64,
                           phaseStart: Date) throws -> Int64 {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw TestError.ioError("Cannot open \(url.lastPathComponent) for writing (\(errnoString())).") }
        _ = fcntl(fd, F_NOCACHE, 1)
        defer {
            _ = fcntl(fd, F_FULLFSYNC, 0) // force to physical media before we time speed
            close(fd)
        }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var writtenInFile: Int64 = 0
        var lastReport = Date()
        var lastReportBytes = totalWritten

        while writtenInFile < size {
            if isCancelled() { throw TestError.cancelled }
            let want = Int(min(Int64(chunkSize), size - writtenInFile))
            fillPattern(&buffer, seed: globalChunkIndex &+ 1, count: want)

            let n: Int = buffer.withUnsafeBytes { raw -> Int in
                writeFully(fd, raw.baseAddress!, want)
            }
            if n < 0 {
                if errno == ENOSPC { return writtenInFile } // card is genuinely full
                throw TestError.ioError("Write error on \(url.lastPathComponent): \(errnoString()).")
            }
            writtenInFile += Int64(n)
            totalWritten += Int64(n)
            globalChunkIndex += 1

            throttleReport(phase: .writing,
                           processed: totalWritten,
                           total: budget,
                           lastReport: &lastReport,
                           lastBytes: &lastReportBytes,
                           phaseStart: phaseStart)
            if n < want { return writtenInFile }
        }
        return writtenInFile
    }

    // MARK: Verify

    /// Reads the file back and compares to the regenerated pattern.
    /// Returns the byte offset of the first mismatch, or nil if all good.
    private func verifyFile(at url: URL,
                            size: Int64,
                            startingChunkIndex globalChunkIndex: inout UInt64,
                            globalByteBase: Int64,
                            totalRead: inout Int64,
                            grandTotal: Int64,
                            phaseStart: Date) throws -> Int64? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw TestError.ioError("Cannot open \(url.lastPathComponent) for reading (\(errnoString())).") }
        _ = fcntl(fd, F_NOCACHE, 1) // bypass the OS cache so we truly read the card
        defer { close(fd) }

        var readBuf = [UInt8](repeating: 0, count: chunkSize)
        var expected = [UInt8](repeating: 0, count: chunkSize)
        var offsetInFile: Int64 = 0
        var lastReport = Date()
        var lastReportBytes = totalRead

        while offsetInFile < size {
            if isCancelled() { throw TestError.cancelled }
            let want = Int(min(Int64(chunkSize), size - offsetInFile))

            let n: Int = readBuf.withUnsafeMutableBytes { raw -> Int in
                readFully(fd, raw.baseAddress!, want)
            }
            if n < 0 { throw TestError.ioError("Read error on \(url.lastPathComponent): \(errnoString()).") }
            if n == 0 { break }

            fillPattern(&expected, seed: globalChunkIndex &+ 1, count: n)

            let mismatch: Int = compareBuffers(readBuf, expected, count: n)
            if mismatch >= 0 {
                return globalByteBase + offsetInFile + Int64(mismatch)
            }

            offsetInFile += Int64(n)
            totalRead += Int64(n)
            globalChunkIndex += 1

            throttleReport(phase: .reading,
                           processed: totalRead,
                           total: grandTotal,
                           lastReport: &lastReport,
                           lastBytes: &lastReportBytes,
                           phaseStart: phaseStart)
        }
        return nil
    }

    // MARK: Pattern

    /// Fills `buffer[0..<count]` deterministically from `seed` using splitmix64.
    private func fillPattern(_ buffer: inout [UInt8], seed: UInt64, count: Int) {
        buffer.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            let wordCount = count / 8
            var state = seed &+ 0x9E3779B97F4A7C15
            for i in 0..<wordCount {
                var z = state
                state = state &+ 0x9E3779B97F4A7C15
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                z = z ^ (z >> 31)
                words[i] = z
            }
            // Tail bytes (count not a multiple of 8) — fill with a derived byte.
            let tailStart = wordCount * 8
            if tailStart < count {
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = z ^ (z >> 31)
                for i in tailStart..<count {
                    raw[i] = UInt8(truncatingIfNeeded: z)
                    z >>= 8
                }
            }
        }
    }

    private func compareBuffers(_ a: [UInt8], _ b: [UInt8], count: Int) -> Int {
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                if memcmp(pa.baseAddress!, pb.baseAddress!, count) == 0 { return -1 }
                // Find the exact first differing byte for a precise capacity estimate.
                let ca = pa.bindMemory(to: UInt8.self)
                let cb = pb.bindMemory(to: UInt8.self)
                for i in 0..<count where ca[i] != cb[i] { return i }
                return -1
            }
        }
    }

    // MARK: POSIX helpers

    private func writeFully(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = write(fd, ptr.advanced(by: total), count - total)
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if n == 0 { break }
            total += n
        }
        return total
    }

    private func readFully(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, ptr.advanced(by: total), count - total)
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if n == 0 { break } // EOF
            total += n
        }
        return total
    }

    // MARK: Progress / cleanup

    private func throttleReport(phase: Phase,
                                processed: Int64,
                                total: Int64,
                                lastReport: inout Date,
                                lastBytes: inout Int64,
                                phaseStart: Date) {
        let now = Date()
        let dt = now.timeIntervalSince(lastReport)
        if dt >= 0.25 {
            let mbps = Double(processed - lastBytes) / dt / 1_000_000.0
            report(phase, processed, total, mbps)
            lastReport = now
            lastBytes = processed
        }
    }

    private func report(_ phase: Phase, _ processed: Int64, _ total: Int64, _ mbps: Double) {
        onProgress(Progress(phase: phase,
                            bytesProcessed: processed,
                            totalBytes: total,
                            currentMBps: mbps))
    }

    private func cleanup(files: [URL], dir: URL) {
        let fm = FileManager.default
        for f in files { try? fm.removeItem(at: f) }
        try? fm.removeItem(at: dir)
    }

    private func failed(_ claimedFree: Int64, _ message: String) -> Result {
        Result(succeeded: false, isGenuine: false, bytesWritten: 0,
               writeMBps: 0, readMBps: 0, claimedFreeBytes: claimedFree,
               verifiedGoodBytes: 0, firstBadOffset: nil, message: message)
    }

    private func freeSpace(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        if let v = try? url.resourceValues(forKeys: keys) {
            if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
                return Int64(important)
            }
            if let avail = v.volumeAvailableCapacity { return Int64(avail) }
        }
        return 0
    }

    private func errnoString() -> String { String(cString: strerror(errno)) }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

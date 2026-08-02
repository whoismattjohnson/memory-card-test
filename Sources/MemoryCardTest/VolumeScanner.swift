//
//  VolumeScanner.swift
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

/// A mounted volume we might test (SD card, USB stick, etc.).
struct CardVolume: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isRemovable: Bool
    let isInternal: Bool

    var totalString: String {
        ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
    }
    var freeString: String {
        ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
    }
    var displayName: String {
        name.isEmpty ? url.lastPathComponent : name
    }
}

enum VolumeScanner {
    /// Lists mounted volumes. By default only removable/ejectable ones (so the
    /// user can't accidentally hammer their boot disk); `includeAll` reveals
    /// every non-root volume for the odd card reader that reports as fixed.
    static func scan(includeAll: Bool) -> [CardVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var result: [CardVolume] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsBrowsable == false { continue }
            if url.path == "/" { continue } // never the boot volume

            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
            let isInternal = v.volumeIsInternal ?? false

            if !includeAll && !removable { continue }

            let total = Int64(v.volumeTotalCapacity ?? 0)
            let free: Int64
            if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
                free = Int64(important)
            } else {
                free = Int64(v.volumeAvailableCapacity ?? 0)
            }

            result.append(CardVolume(
                id: url,
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                totalCapacity: total,
                availableCapacity: free,
                isRemovable: removable,
                isInternal: isInternal
            ))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

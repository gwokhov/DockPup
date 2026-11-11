// Copyright (C) 2026 Gwokhou
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect

    static func connected() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return Display(id: id, name: screen.localizedName, frame: CGDisplayBounds(id))
        }
    }

    func exposedBottomEdges(among displays: [Display]) -> [CGRect] {
        var spans = [frame.minX...frame.maxX]
        // Keep shared edges traversable; protect only exposed bottom edges.
        for other in displays where other.id != id && other.frame.minY <= frame.maxY + 0.5 && other.frame.maxY > frame.maxY + 0.5 {
            spans = spans.flatMap { span -> [ClosedRange<CGFloat>] in
                let left = max(span.lowerBound, other.frame.minX)
                let right = min(span.upperBound, other.frame.maxX)
                guard left < right else { return [span] }
                var remaining: [ClosedRange<CGFloat>] = []
                if span.lowerBound < left { remaining.append(span.lowerBound...left) }
                if right < span.upperBound { remaining.append(right...span.upperBound) }
                return remaining
            }
        }
        return spans.map {
            CGRect(x: $0.lowerBound, y: frame.maxY - 2, width: $0.upperBound - $0.lowerBound, height: 2)
        }
    }
}

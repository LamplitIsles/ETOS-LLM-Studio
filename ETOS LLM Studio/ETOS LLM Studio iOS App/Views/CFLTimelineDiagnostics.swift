#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore
import ExyteChat
import ETOSCore

// Temporary #5401 instrumentation. Only numeric layout data and fixed event
// names are written. Never pass message content, identifiers, URLs or errors.
@MainActor
enum CFLTimelineDiagnostics {
    private static var started = false
    private static var lines: [String] = []
    private static var flushPending = false
    private enum RowKey: Hashable {
        case message(CFLDisplayMessage.ID)
        case pending(otherTarget: Bool, target: String, session: String, operation: String)
        case space
    }
    private static var keys: [RowKey: Int] = [:]
    private static let writer = DispatchQueue(label: "etos.timeline-layout-diagnostics")
    private static var destination: URL?
    private static var runStart = CACurrentMediaTime()
    static var markers: [WeakMarker] = []

    struct WeakMarker { weak var view: CFLTimelineRowMarker.Marker? }

    static func token(_ row: CFLTimelineRow) -> Int {
        let key: RowKey
        switch row {
        case .message(let item): key = .message(item.id)
        case .pending(let item): key = .pending(otherTarget: false, target: item.target, session: item.sessionId, operation: item.operationId)
        case .otherTarget(let item): key = .pending(otherTarget: true, target: item.target, session: item.sessionId, operation: item.operationId)
        case .bottomSpace: key = .space
        }
        if let value = keys[key] { return value }
        let value = keys.count + 1
        keys[key] = value
        return value
    }

    static func event(_ name: String, _ fields: String = "") {
        if !started {
            started = true
            runStart = CACurrentMediaTime()
            destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("etos-timeline-layout.log")
            lines.append("[DEBUG-TIMELINE-5401] 0.000 run-start version=1\n")
        }
        lines.append(String(format: "[DEBUG-TIMELINE-5401] %.3f %@ %@\n", CACurrentMediaTime() - runStart, name, fields))
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let batch = Data(lines.joined().utf8)
            lines.removeAll(keepingCapacity: true)
            flushPending = false
            guard let file = destination else { return }
            writer.async { write(batch, to: file) }
        }
    }

    nonisolated private static func write(_ data: Data, to file: URL) {
        // Two bounded files, 2 MiB each. Touch only these diagnostic files.
        do {
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > 2 * 1024 * 1024 {
                let previous = file.deletingLastPathComponent().appendingPathComponent("etos-timeline-layout.previous.log")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Error descriptions may contain paths. Do not log them.
            print("[DEBUG-TIMELINE-5401] diagnostic-write-failed")
        }
    }

    static func rows(_ name: String, old: [CFLTimelineRow], new: [CFLTimelineRow]) {
        let before = Dictionary(old.map { (token($0), $0.message) }, uniquingKeysWith: { _, last in last })
        let after = Dictionary(new.map { (token($0), $0.message) }, uniquingKeysWith: { _, last in last })
        let added = Set(after.keys).subtracting(before.keys).sorted()
        let removed = Set(before.keys).subtracting(after.keys).sorted()
        let changed = Set(before.keys).intersection(after.keys).filter { before[$0] != after[$0] }.sorted()
        let order = new.suffix(40).map { String(token($0)) }.joined(separator: ",")
        event(name, "old=\(old.count) new=\(new.count) added=\(added) removed=\(removed) changed=\(changed) tail=\(order)")
    }
}

struct CFLTimelineRowMarker: UIViewRepresentable {
    let token: Int
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.token = token
        CFLTimelineDiagnostics.markers.removeAll { $0.view == nil }
        CFLTimelineDiagnostics.markers.append(.init(view: view))
        return view
    }
    func updateUIView(_ view: Marker, context: Context) {
        if view.token != token { CFLTimelineDiagnostics.event("row-reused", "old=\(view.token) new=\(token)") }
        view.token = token
    }
    final class Marker: UIView {
        var token = 0
        override func didMoveToWindow() {
            super.didMoveToWindow()
            CFLTimelineDiagnostics.event(window == nil ? "row-detached" : "row-attached", "row=\(token)")
        }
    }
}

struct CFLTimelineLayoutProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer {
        let view = Observer()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: Observer, context: Context) { view.attach() }
    static func dismantleUIView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: UIView {
        private weak var table: UITableView?
        private var link: CADisplayLink?
        private var notifications: [NSObjectProtocol] = []
        private var previous = ""

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() }
            else { DispatchQueue.main.async { [weak self] in self?.attach() } }
        }
        override func layoutSubviews() { super.layoutSubviews(); attach() }

        func attach() {
            guard window != nil, table == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let found = findTable(view) {
                    table = found
                    let timer = CADisplayLink(target: self, selector: #selector(sample))
                    timer.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
                    timer.add(to: .main, forMode: .common)
                    link = timer
                    notifications = [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification].map { name in
                        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                            let height = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
                            Task { @MainActor in
                                CFLTimelineDiagnostics.event(name == UIResponder.keyboardWillChangeFrameNotification ? "keyboard-will" : "keyboard-did", "height=\(Int(height)) duration=\(duration)")
                            }
                        }
                    }
                    CFLTimelineDiagnostics.event("table-attached", "ios=\(UIDevice.current.systemVersion) estimatedRowHeight=\(found.estimatedRowHeight)")
                    return
                }
                ancestor = view.superview
            }
        }

        private func findTable(_ view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            for child in view.subviews where child !== self {
                if let table = findTable(child) { return table }
            }
            return nil
        }

        @objc private func sample() {
            guard let table, let window = table.window else { return }
            func value(_ x: CGFloat) -> String { String(format: "%.1f", x) }
            let viewport = table.convert(table.bounds, to: window)
            let markers = CFLTimelineDiagnostics.markers.compactMap { $0.view }.compactMap { marker -> String? in
                guard marker.window === window else { return nil }
                let rect = marker.convert(marker.bounds, to: window)
                guard rect.intersects(viewport) else { return nil }
                return "\(marker.token):\(value(rect.minY)):\(value(rect.height))"
            }.sorted().joined(separator: ",")
            let cells = table.visibleCells.compactMap { cell -> String? in
                guard let index = table.indexPath(for: cell) else { return nil }
                let rect = cell.convert(cell.bounds, to: window)
                let animated = cell.layer.presentation().map { table.convert($0.frame, to: window).minY } ?? rect.minY
                return "\(index.section).\(index.row):\(value(rect.minY)):\(value(rect.height)):\(value(animated))"
            }.sorted().joined(separator: ",")
            let fields = "offset=\(value(table.contentOffset.y)) content=\(value(table.contentSize.height)) bounds=\(value(table.bounds.height)) width=\(value(table.bounds.width)) " +
                "insets=\(value(table.adjustedContentInset.top)),\(value(table.adjustedContentInset.bottom)) " +
                "tracking=\(table.isTracking ? 1 : 0) dragging=\(table.isDragging ? 1 : 0) decel=\(table.isDecelerating ? 1 : 0) " +
                "pan=\(value(table.panGestureRecognizer.translation(in: table).y)) velocity=\(value(table.panGestureRecognizer.velocity(in: table).y)) " +
                "cells=\(cells) rows=\(markers)"
            if fields != previous { previous = fields; CFLTimelineDiagnostics.event("frame", fields) }
        }

        func stop() {
            link?.invalidate(); link = nil; table = nil
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications.removeAll()
            CFLTimelineDiagnostics.event("table-detached")
        }
    }
}
#endif

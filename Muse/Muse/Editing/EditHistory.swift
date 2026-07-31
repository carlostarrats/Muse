//
//  EditHistory.swift
//  Muse
//
//  Session-only undo/redo over EditStack — a value type, ported from Surface
//  Camera's EditHistory (state array + cursor, push-dedupe, truncate-forward,
//  bounded capacity).
//
//  Push fires on gesture END only (`EditSession.commitGesture` is the single
//  call site), never per slider tick — otherwise a single drag buries the
//  user's real previous state under a hundred interpolated ones.
//
//  This history is deliberately NOT persisted. Cross-session "go back" is the
//  stack itself plus snapshots/versions (`edit_versions`).
//

import Foundation

nonisolated struct EditHistory: Equatable, Sendable {
    /// Bounded so a long editing session can't grow without limit; oldest
    /// states drop off the back.
    static let capacity = 100

    private var states: [EditStack]
    private var cursor: Int

    init(initial: EditStack) {
        states = [initial]
        cursor = 0
    }

    var current: EditStack { states[cursor] }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < states.count - 1 }

    mutating func push(_ state: EditStack) {
        // Dedupe: committing a gesture that changed nothing (a click that
        // didn't move a slider) must not consume an undo step.
        guard state != current else { return }
        // New branch — anything ahead of the cursor is discarded.
        if cursor + 1 < states.count {
            states.removeSubrange((cursor + 1)...)
        }
        states.append(state)
        cursor = states.count - 1
        if states.count > Self.capacity {
            let overflow = states.count - Self.capacity
            states.removeFirst(overflow)
            cursor -= overflow
        }
    }

    mutating func undo() -> EditStack? {
        guard canUndo else { return nil }
        cursor -= 1
        return current
    }

    mutating func redo() -> EditStack? {
        guard canRedo else { return nil }
        cursor += 1
        return current
    }
}

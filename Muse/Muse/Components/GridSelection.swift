//
//  GridSelection.swift
//  Muse
//
//  Pure selection math for the grid: turn a click (single / Cmd-toggle /
//  Shift-range) plus the current selection + anchor + grid order into the new
//  selection + anchor. No UI — unit tested. Keys are standardized file paths.
//

import Foundation

enum GridSelection {
    enum Click {
        case single(String)   // plain click: select only this
        case toggle(String)   // Cmd-click: add/remove this
        case range(String)    // Shift-click: anchor…this, inclusive
    }

    struct Result { var selection: Set<String>; var anchor: String? }

    static func apply(_ click: Click, to selection: Set<String>,
                      anchor: String?, order: [String]) -> Result {
        switch click {
        case .single(let p):
            return Result(selection: [p], anchor: p)
        case .toggle(let p):
            var s = selection
            if s.contains(p) { s.remove(p) } else { s.insert(p) }
            return Result(selection: s, anchor: p)
        case .range(let p):
            guard let a = anchor,
                  let i = order.firstIndex(of: a),
                  let j = order.firstIndex(of: p) else {
                return Result(selection: [p], anchor: p)
            }
            let lo = min(i, j), hi = max(i, j)
            return Result(selection: Set(order[lo...hi]), anchor: a)
        }
    }
}

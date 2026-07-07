//
//  CollectionAppearance.swift
//  Muse
//
//  Pure lookup tables + resolution rules for the per-collection sidebar
//  appearance (feat/next-128): 27 preset color tokens and a curated SF Symbol
//  catalog for the right-click "Change Symbol & Color…" modal. Storage is the canonical
//  TOKEN / symbol NAME (never a hex or a rendered value) so the DB stays
//  appearance-agnostic; resolution to a Color happens at display time.
//
//  Both fields nil = the default look the sidebar has always had
//  (square.stack.3d.up, primary / accent-when-selected).
//

import SwiftUI
import AppKit

enum CollectionAppearance {

    /// The default sidebar collection symbol (pre-customization look).
    static let defaultIcon = "square.stack.3d.up"

    /// The 27 preset swatches, in picker order — with the Default cell they
    /// fill a 7-row × 4 grid alongside the 6×6 symbol grid. SPECTRUM order
    /// (owner call, 2026-07-07): reds → oranges → yellows → greens → teals →
    /// blues → violets → pinks, reading left-to-right then down, with each
    /// hue's deep variant beside its mid-tone. Fixed values chosen to stay
    /// legible on both the light and dark sidebar. Tokens are the stored
    /// identity — renaming one orphans saved rows, so treat the strings as
    /// frozen.
    static let colorTokens: [(token: String, color: Color)] = [
        ("maroon",  Color(red: 0.725, green: 0.110, blue: 0.110)),
        ("red",     Color(red: 0.937, green: 0.267, blue: 0.267)),
        ("rose",    Color(red: 0.957, green: 0.247, blue: 0.369)),
        ("rust",    Color(red: 0.761, green: 0.255, blue: 0.047)),
        ("orange",  Color(red: 0.976, green: 0.451, blue: 0.086)),
        ("amber",   Color(red: 0.961, green: 0.620, blue: 0.043)),
        ("gold",    Color(red: 0.631, green: 0.384, blue: 0.027)),
        ("yellow",  Color(red: 0.918, green: 0.702, blue: 0.031)),
        ("lime",    Color(red: 0.518, green: 0.800, blue: 0.086)),
        ("olive",   Color(red: 0.302, green: 0.486, blue: 0.059)),
        ("green",   Color(red: 0.133, green: 0.773, blue: 0.369)),
        ("forest",  Color(red: 0.082, green: 0.502, blue: 0.239)),
        ("emerald", Color(red: 0.063, green: 0.725, blue: 0.506)),
        ("pine",    Color(red: 0.059, green: 0.463, blue: 0.431)),
        ("teal",    Color(red: 0.078, green: 0.722, blue: 0.651)),
        ("cyan",    Color(red: 0.024, green: 0.714, blue: 0.831)),
        ("sky",     Color(red: 0.055, green: 0.647, blue: 0.914)),
        ("ocean",   Color(red: 0.012, green: 0.412, blue: 0.631)),
        ("blue",    Color(red: 0.231, green: 0.510, blue: 0.965)),
        ("navy",    Color(red: 0.114, green: 0.306, blue: 0.847)),
        ("indigo",  Color(red: 0.388, green: 0.400, blue: 0.945)),
        ("violet",  Color(red: 0.545, green: 0.361, blue: 0.965)),
        ("grape",   Color(red: 0.494, green: 0.133, blue: 0.808)),
        ("purple",  Color(red: 0.659, green: 0.333, blue: 0.969)),
        ("plum",    Color(red: 0.635, green: 0.110, blue: 0.686)),
        ("fuchsia", Color(red: 0.851, green: 0.275, blue: 0.937)),
        ("pink",    Color(red: 0.925, green: 0.286, blue: 0.600)),
    ]

    /// The curated symbol grid (36 = 6×6), default stack icon first. OUTLINE
    /// variants on purpose — the app's iconography (toolbar, sidebar) is
    /// outline-weight, so filled picker symbols read foreign (owner call,
    /// 2026-07-07); symbols with no outline variant (sparkles, music.note,
    /// airplane, mappin, fork.knife) keep their only form. Every name must
    /// exist on the min-OS SF Symbols set — `isValidSymbol` is unit-tested
    /// over this list so a typo can't ship a blank cell.
    static let symbols: [String] = [
        defaultIcon,
        "star", "heart", "tag", "bookmark", "flag",
        "bolt", "sparkles", "flame", "leaf", "camera",
        "photo", "film", "music.note", "paintbrush",
        "paintpalette", "folder", "book", "briefcase",
        "cart", "gift", "gamecontroller", "airplane",
        "car", "house", "building.2", "globe.americas",
        "mappin", "cup.and.saucer", "fork.knife", "pawprint",
        "person", "moon.stars", "sun.max", "lightbulb",
        "crown",
    ]

    /// Resolve a stored color token. nil, or a token this build doesn't know
    /// (e.g. a future rename), yields nil — the caller falls back to the
    /// default icon style. Never throws, never guesses.
    static func color(for token: String?) -> Color? {
        guard let token else { return nil }
        return colorTokens.first(where: { $0.token == token })?.color
    }

    /// Resolve a stored symbol name to something that will actually render:
    /// nil or a name this OS's SF Symbols set lacks falls back to the default
    /// stack icon (a customized collection must never show a blank).
    static func resolvedIcon(_ name: String?) -> String {
        guard let name, isValidSymbol(name) else { return defaultIcon }
        return name
    }

    /// True when the name exists in this OS's SF Symbols catalog.
    static func isValidSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Localized, human-readable name for a color token — the swatch's
    /// VoiceOver label. Literal switch (not lookup) so the compiler extracts
    /// every key for localization. Unknown token → the token itself, so a
    /// future addition degrades to readable-but-English, never silence.
    static func displayName(forToken token: String) -> String {
        switch token {
        case "red":     return String(localized: "Red")
        case "orange":  return String(localized: "Orange")
        case "amber":   return String(localized: "Amber")
        case "yellow":  return String(localized: "Yellow")
        case "lime":    return String(localized: "Lime")
        case "green":   return String(localized: "Green")
        case "emerald": return String(localized: "Emerald")
        case "teal":    return String(localized: "Teal")
        case "cyan":    return String(localized: "Cyan")
        case "sky":     return String(localized: "Sky")
        case "blue":    return String(localized: "Blue")
        case "indigo":  return String(localized: "Indigo")
        case "violet":  return String(localized: "Violet")
        case "purple":  return String(localized: "Purple")
        case "fuchsia": return String(localized: "Fuchsia")
        case "pink":    return String(localized: "Pink")
        case "rose":    return String(localized: "Rose")
        case "maroon":  return String(localized: "Maroon")
        case "rust":    return String(localized: "Rust")
        case "gold":    return String(localized: "Gold")
        case "olive":   return String(localized: "Olive")
        case "forest":  return String(localized: "Forest")
        case "pine":    return String(localized: "Pine")
        case "ocean":   return String(localized: "Ocean")
        case "navy":    return String(localized: "Navy")
        case "grape":   return String(localized: "Grape")
        case "plum":    return String(localized: "Plum")
        default:        return token
        }
    }

    /// Localized, human-readable name for a catalog symbol — the icon cell's
    /// VoiceOver label. Same literal-switch rule as displayName(forToken:).
    static func displayName(forSymbol name: String) -> String {
        switch name {
        case defaultIcon:        return String(localized: "Stack (default)")
        case "star":             return String(localized: "Star")
        case "heart":            return String(localized: "Heart")
        case "tag":              return String(localized: "Tag")
        case "bookmark":         return String(localized: "Bookmark")
        case "flag":             return String(localized: "Flag")
        case "bolt":             return String(localized: "Bolt")
        case "sparkles":         return String(localized: "Sparkles")
        case "flame":            return String(localized: "Flame")
        case "leaf":             return String(localized: "Leaf")
        case "camera":           return String(localized: "Camera")
        case "photo":            return String(localized: "Photo")
        case "film":             return String(localized: "Film")
        case "music.note":       return String(localized: "Music Note")
        case "paintbrush":       return String(localized: "Paintbrush")
        case "paintpalette":     return String(localized: "Palette")
        case "folder":           return String(localized: "Folder")
        case "book":             return String(localized: "Book")
        case "briefcase":        return String(localized: "Briefcase")
        case "cart":             return String(localized: "Cart")
        case "gift":             return String(localized: "Gift")
        case "gamecontroller":   return String(localized: "Game Controller")
        case "airplane":         return String(localized: "Airplane")
        case "car":              return String(localized: "Car")
        case "house":            return String(localized: "House")
        case "building.2":       return String(localized: "Buildings")
        case "globe.americas":   return String(localized: "Globe")
        case "mappin":           return String(localized: "Map Pin")
        case "cup.and.saucer":   return String(localized: "Cup")
        case "fork.knife":       return String(localized: "Fork and Knife")
        case "pawprint":         return String(localized: "Paw Print")
        case "person":           return String(localized: "Person")
        case "moon.stars":       return String(localized: "Moon and Stars")
        case "sun.max":          return String(localized: "Sun")
        case "lightbulb":        return String(localized: "Lightbulb")
        case "crown":            return String(localized: "Crown")
        default:                    return name
        }
    }
}

//
//  ModalScroll.swift
//  Muse
//
//  Marks the growable part of a modal card. It deliberately does NOT scroll:
//  the scrolling decision belongs to the presenter, which is the only place
//  that knows how much room the window has.
//
//  History, so this isn't "simplified" back: a modal used to wrap this content
//  in its own `ScrollView`, and a ScrollView is GREEDY — it takes every point
//  offered, so each card grew to the full window cap with its content floating
//  in the middle even when that content was three rows tall. Two fixes inside
//  the card were tried against the running app and both failed: `ViewThatFits`
//  resolves to its greedy candidate when asked for an ideal height (which is
//  exactly what a content-hugging card asks for), and measuring the content with
//  a `GeometryReader` preference never settled either. The presenter's
//  `ViewThatFits` works because the ZStack proposes the real window height to
//  it, so "does this fit?" is a question it can actually answer.
//

import SwiftUI

struct ModalScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

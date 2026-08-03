//
//  EditorCardBuilder.swift
//  Muse
//
//  Module → card. The one place that knows a section id means a particular
//  EditorSection with a particular heading, accessory and body.
//
//  Its own file for a compile-time reason as much as a legibility one: a
//  twelve-way switch inside a @ViewBuilder nests _ConditionalContent twelve
//  deep, and that type-checks far faster with the branches away from the rest
//  of the view.
//
//  The headings come from `EditorModule.title`, not from literals here, so the
//  panel and the Customize list can never disagree about what a card is called.
//

import SwiftUI

extension EditorView {
    /// One card, built for the module the workspace asked for.
    ///
    /// INSIGHTS is conditional on having something to say — that is a
    /// hidden-by-ABSENCE, which is not the same as a user-hidden module, and is
    /// why it also drops out of the Customize list when empty.
    @ViewBuilder
    func card(for module: EditorModule) -> some View {
        switch module {
        case .tools:
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.tools)) { toolsSection }
        case .histogram:
            // Was "SCOPES" — a word from broadcast video that says nothing to
            // someone looking at their own photo. It IS a histogram (plus the
            // plain-English clipping read-out), so it says so.
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.histogram)) {
                ScopesPanel(session: session)
            }
        case .insights:
            if hasInsights {
                EditorSection(title: module.title, ink: ink,
                              isExpanded: expansion(Section.insights)) { insightsSection }
            }
        case .history:
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.history)) {
                EditVersionsList(session: session)
            }
        case .looks:
            // "Looks" is film-industry shorthand; this card is presets, LUTs
            // and copy/paste of adjustments — all of it "settings you saved and
            // can apply again", which is what a STYLE is in plain English.
            EditorSection(title: module.title, ink: ink,
                          accessory: stylesModeButtons,
                          summary: stylesSummary,
                          isExpanded: expansion(Section.looks)) { looksTab }
        case .light:
            EditorSection(title: module.title, ink: ink,
                          accessory: autoAndReset(
                              autoHelp: String(localized: "Auto Light"),
                              auto: {
                                  Task {
                                      guard let r = await session.autoToneResult() else { return }
                                      AutoToneApply.light(r, onto: &session.draft)
                                      session.commitGesture()
                                  }
                              },
                              resetHelp: String(localized: "Reset Light"),
                              reset: {
                                  session.draft.setTone { $0 = .neutral }
                                  session.draft.setPresence { $0 = .neutral }
                                  session.draft.setCurve { $0 = .neutral }
                                  session.commitGesture()
                              }),
                          isExpanded: expansion(Section.light)) { lightTab }
        case .zones:
            // A distinct way of working (paint tone onto the photo by zone),
            // not one more slider — which is why it is its own card.
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Tone Zones")) {
                              session.draft.setToneZone { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.zones)) {
                ToneZoneStrip(session: session)
            }
        case .color:
            EditorSection(title: module.title, ink: ink,
                          accessory: autoAndReset(
                              autoHelp: String(localized: "Auto Color"),
                              auto: {
                                  Task {
                                      guard let r = await session.autoToneResult() else { return }
                                      AutoToneApply.color(r, onto: &session.draft)
                                      session.commitGesture()
                                  }
                              },
                              resetHelp: String(localized: "Reset Color"),
                              reset: {
                                  session.draft.setColor { $0 = .neutral }
                                  session.commitGesture()
                              }),
                          isExpanded: expansion(Section.color)) { colorTab }
        case .hsl:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Color Mix")) {
                              session.draft.setHSL { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.hsl)) { hslSection }
        case .splitTone:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Split Tone")) {
                              session.draft.setSplitTone { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.splitTone)) { splitToneSection }
        case .effects:
            // Called EFFECTS rather than the spec's original "Character" for
            // the same reason SCOPES became HISTOGRAM: the heading has to say
            // what it does to someone looking at their own photo.
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Effects")) {
                              session.draft.setVignette { $0 = .neutral }
                              session.draft.setGrain { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.effects)) { effectsSection }
        case .crop:
            EditorSection(title: module.title, ink: ink,
                          accessory: cropResetButton,
                          isExpanded: expansion(Section.crop)) { cropSection }
        }
    }
}

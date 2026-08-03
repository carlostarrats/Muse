//
//  EditorCardsCrop.swift
//  Muse
//
//  CROP & STRAIGHTEN. Its own file because it is the largest single card and
//  the only one whose control writes into a DIFFERENT coordinate space than
//  the one it is drawn in — see CropDragMath and the durable constraint about
//  EditRenderer.applyGeometry cropping BEFORE it flips and quarter-turns.
//  Moved verbatim out of EditorView.swift; see EditorCardsLeft.swift for why.
//

import SwiftUI

extension EditorView {
    // MARK: - Crop & straighten

    /// Geometry shipped with a full model, renderer, codec and Lightroom
    /// importer and NO editor UI — the only writers were the importer and the
    /// social export's crop step. This card is the missing half.
    ///
    /// TWO tools, labelled as such: framing (a mode you enter, frame, and
    /// Apply) and orientation (straighten, rotate, flip — direct actions that
    /// have nothing to do with the crop rectangle and must not be gated behind
    /// entering crop mode).
    ///
    /// Only the crop RECTANGLE is transactional. It has to be: it is the one
    /// control you set up over several drags before you mean it.
    var cropSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            effectsGroupLabel(String(localized: "Crop"))

            EditorToolRow(systemName: "crop",
                          label: session.cropMode
                              ? String(localized: "Cancel Crop")
                              : String(localized: "Crop"),
                          isActive: session.cropMode,
                          action: { session.cropMode.toggle() })

            // Spaced off the row above: it is a different KIND of control (a
            // choice, not a switch) and read as attached to it.
            cropAspectMenu
                .padding(.top, panelTheme.spacingS)
                .padding(.bottom, 2)

            EditorToolRow(systemName: "rectangle.portrait.rotate",
                          label: String(localized: "Portrait / Landscape"),
                          isActive: cropPortrait,
                          isEnabled: session.cropMode && cropAspect.supportsOrientation,
                          action: {
                cropPortrait.toggle()
                selectAspect(cropAspect)
            })

            if session.cropMode {
                HStack {
                    cropApplyRow
                    Spacer(minLength: 0)
                }
                .padding(.top, panelTheme.spacingS)
            }

            Divider().padding(.vertical, 6)

            effectsGroupLabel(String(localized: "Straighten"))

            EditSlider(label: String(localized: "Angle"),
                       value: straightenBinding, range: -45...45,
                       onCommit: session.commitGesture)

            // Rotate and flip are NOT crop operations — they turn the whole
            // photo — so they apply directly and are never gated behind crop
            // mode.
            EditorToolRow(systemName: "rotate.left",
                          label: String(localized: "Rotate Left"),
                          action: { turnPhoto(by: -1) })
            EditorToolRow(systemName: "rotate.right",
                          label: String(localized: "Rotate Right"),
                          action: { turnPhoto(by: 1) })
            EditorToolRow(systemName: "arrow.left.and.right.square",
                          label: String(localized: "Flip Horizontal"),
                          isActive: session.draft.geometryParams?.flipH ?? false,
                          action: { flipPhoto(horizontal: true) })
            EditorToolRow(systemName: "arrow.up.and.down.square",
                          label: String(localized: "Flip Vertical"),
                          isActive: session.draft.geometryParams?.flipV ?? false,
                          action: { flipPhoto(horizontal: false) })
        }
    }

    /// Turning or flipping while the crop card is open changes what DISPLAY
    /// space means; `EditSession.draft`'s own `didSet` re-places the pending
    /// frame onto the new orientation, so it stays on the same part of the
    /// picture. These two exist only to normalize the turn count.
    func turnPhoto(by delta: Int) {
        session.draft.setGeometry {
            $0.quarterTurns = CropDragMath.normalizedTurns($0.quarterTurns + delta)
        }
        session.commitGesture()
    }

    func flipPhoto(horizontal: Bool) {
        session.draft.setGeometry {
            if horizontal { $0.flipH.toggle() } else { $0.flipV.toggle() }
        }
        session.commitGesture()
    }

    /// A real dropdown — bordered as well as filled, because as a bare label
    /// with a chevron it did not read as something you could press.
    var cropAspectMenu: some View {
        Menu {
            ForEach(CropAspectPreset.modes) { p in
                Button(p.menuTitle()) { selectAspect(p) }
            }
            Divider()
            ForEach(CropAspectPreset.shapes) { p in
                Button(p.menuTitle(portrait: cropPortrait)) { selectAspect(p) }
            }
        } label: {
            Text(cropAspect.menuTitle(portrait: cropPortrait))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Standard pop-up treatment — the platform already draws a control that
        // reads as pressable, and the hand-rolled border was a second, worse
        // version of it.
        .controlSize(.small)
        .disabled(!session.cropMode)
        .accessibilityLabel(Text("Crop shape"))
        .help(Text("Crop shape"))
    }

    /// Apply is the FILLED accent button — it is the one action that commits,
    /// and as a small grey checkmark in the heading it read as decoration.
    var cropApplyRow: some View {
        Button {
            guard let pending = session.pendingCropInSourceSpace else { return }
            session.draft.setGeometry { $0.crop = pending }
            session.commitGesture()
            session.cropMode = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Apply Crop")
            }
            .font(panelTheme.labelFont.weight(.semibold))
            .foregroundStyle(panelTheme.selectionInk)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(panelTheme.selectionFill)
                    // Hover is a TINT and nothing else — the app's hover
                    // treatment everywhere. It was a shadow-and-lift here,
                    // which read as a different kind of control. The white
                    // wash works whichever way the accent resolves, since
                    // PanelContrast can hand this button a light or a dark
                    // fill and a hard-coded "brighter" would be wrong for one.
                    .overlay(Capsule(style: .continuous)
                        .fill(Color.white.opacity(isApplyHot ? 0.18 : 0))))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!session.cropHasPendingChange)
        .opacity(session.cropHasPendingChange ? 1 : 0.35)
        .onHover { applyCropHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isApplyHot)
        .help(Text("Apply Crop"))
    }

    /// Hover only counts while the button can actually DO something — a
    /// disabled control that lights up under the pointer is a promise it will
    /// not keep.
    var isApplyHot: Bool {
        applyCropHovering && session.cropHasPendingChange
    }

    /// The card's Reset, in the HEADING like every other card's — it clears the
    /// whole geometry group (crop, angle, rotation, flips), which is what
    /// "reset this card" means everywhere else in the editor.
    var cropResetButton: AnyView {
        resetButton(String(localized: "Reset Crop & Straighten")) {
            session.draft.setGeometry { $0 = .neutral }
            session.pendingCrop = session.cropMode ? .full : nil
            cropAspect = .original
            cropPortrait = false
            session.commitGesture()
        }
    }

    /// Picking a shape refits the pending frame; Freeform leaves whatever is on
    /// screen alone, since its whole point is that you place it yourself.
    ///
    /// "Original" resolves to the STORED crop when that is already full, so
    /// choosing it changes nothing and the Apply button correctly stays down —
    /// picking the option you are already on is not an edit.
    func selectAspect(_ p: CropAspectPreset) {
        cropAspect = p
        guard session.cropMode else { return }
        switch p.id {
        case "original":
            session.pendingCrop = .full
        case "freeform":
            break
        default:
            guard let ratio = p.ratio(portrait: cropPortrait) else { return }
            session.pendingCrop = CropDragMath.fit(aspect: ratio, into: session.displayAspect)
        }
    }

    /// Straighten writes the angle AND the inset crop that keeps the photo a
    /// filled rectangle — `applyGeometry` rotates and then crops with no inset
    /// of its own, so without this the corners go transparent. Lightroom and
    /// Apple Photos both pull the crop in as you rotate.
    ///
    /// It applies directly rather than through Apply: it is a slider, and every
    /// other slider in the editor takes effect as you drag it. It only
    /// auto-manages a crop it OWNS — full frame, or the inset it wrote itself;
    /// a frame the user dragged is theirs.
    var straightenBinding: Binding<Double> {
        Binding(get: { session.draft.geometryParams?.straightenDegrees ?? 0 },
                set: { degrees in
            // SOURCE aspect, not display: `applyGeometry` straightens and then
            // crops, both in source space, so the inscribed-rect problem lives
            // there. The inset it produces is a CENTRED rect with equal
            // normalized sides, which is orientation-invariant, so it can be
            // written to `crop` directly without a mapping.
            let aspect = session.imageAspect
            let existing = session.draft.geometryParams ?? .neutral
            let previous = existing.straightenDegrees
            let current = existing.crop ?? .full
            let ownsCrop = current.isFull
                || current == CropDragMath.straightenInset(degrees: previous, aspect: aspect)

            session.draft.setGeometry { g in
                g.straightenDegrees = degrees
                guard ownsCrop else { return }
                g.crop = degrees == 0
                    ? .full
                    : CropDragMath.straightenInset(degrees: degrees, aspect: aspect)
            }
        })
    }
}

//
//  AVURLAsset+NoNetwork.swift
//  Muse
//
//  Every AVFoundation asset in Muse MUST be built through these helpers so a
//  malicious media file can't turn "no network except Sparkle + the opt-in
//  Drive publish" into a lie.
//
//  A QuickTime *reference movie* (a valid `.mov` whose `moov` carries an
//  `rmra`/`rdrf` data-reference atom of type `url `) — or an HLS master
//  playlist — can point a track at a REMOTE URL. When AVFoundation opens such
//  an asset it resolves that external reference, issuing a network request to
//  the attacker's host and deanonymizing the viewer's IP. Muse opens video/
//  audio assets not only on playback but on mere FOLDER OPEN (thumbnail
//  prewarm) and hero preview (palette / natural-size / metadata), so a planted
//  file would beacon with no click at all.
//
//  `AVURLAssetReferenceRestrictionsKey = .forbidAll` refuses every external
//  data reference (local→remote, remote→local, cross-site). Muse only ever
//  plays self-contained LOCAL files, which carry no external references, so
//  nothing legitimate is affected — this purely closes the egress.
//

import AVFoundation

extension AVURLAsset {
    /// The ONLY sanctioned way to make an `AVURLAsset` in Muse — pins reference
    /// restrictions to `.forbidAll` so a reference-movie / HLS remote data
    /// reference can't phone home. Use this everywhere instead of
    /// `AVURLAsset(url:)` / `AVAsset(url:)`.
    static func noNetwork(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
    }
}

extension AVPlayer {
    /// Builds a player over a `.noNetwork` asset — `AVPlayer(url:)` would create
    /// an UNRESTRICTED `AVURLAsset` internally, so never use it directly.
    static func noNetwork(url: URL) -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset.noNetwork(url: url)))
    }
}

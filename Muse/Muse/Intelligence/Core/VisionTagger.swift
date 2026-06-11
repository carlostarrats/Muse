import Foundation

final class VisionTagger: Tagger {
    let modelVersion = "vision-v1"
    func analyze(url: URL) async -> TaggerOutput? { nil }   // real body: Task 6
}

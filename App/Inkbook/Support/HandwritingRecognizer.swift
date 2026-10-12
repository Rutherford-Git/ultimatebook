import CoreGraphics
import Foundation
import InkbookCore
import Vision

/// On-device handwriting recognition (Apple Vision). Nothing leaves the iPad.
enum HandwritingRecognizer {
    /// Recognizes text in an ink-only page image and returns a reading-order transcript.
    /// - Parameter pageSize: page size in points, used to place words for line grouping.
    static func transcript(of image: CGImage, pageSize: InkbookCore.Size) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            // Reading results synchronously after perform() avoids the completion handler, which
            // Vision may or may not call when perform() throws.
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let words = (request.results ?? []).compactMap { observation -> TextLayout.Word? in
                guard let best = observation.topCandidates(1).first else { return nil }
                // Vision boxes are normalized with a bottom-left origin.
                let b = observation.boundingBox
                return TextLayout.Word(
                    frame: InkbookCore.Rect(x: b.minX * pageSize.width, y: (1 - b.maxY) * pageSize.height,
                                            width: b.width * pageSize.width, height: b.height * pageSize.height),
                    text: best.string)
            }
            return TextLayout.transcript(words)
        }.value
    }
}

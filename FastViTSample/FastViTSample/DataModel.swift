import CoreImage
import CoreML
import SwiftUI
import os

fileprivate let targetSize = CGSize(width: 256, height: 256)


struct PredictionResult: Hashable {
    let label: String
    let probability: Double
}

final class DataModel: ObservableObject {
    let camera = Camera()
    let context = CIContext()

    /// The depth model.
    var model: FastViTMA36F16?

    /// A pixel buffer used as input to the model.
    let inputPixelBuffer: CVPixelBuffer

    /// The last image captured from the camera.
    var lastImage = OSAllocatedUnfairLock<CIImage?>(uncheckedState: nil)

    /// The resulting depth image.
    @Published var prediction: [PredictionResult]?
    
    init() {
        // Create a reusable buffer to avoid allocating memory for every model invocation
        var buffer: CVPixelBuffer!
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(targetSize.width),
            Int(targetSize.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess else {
            fatalError("Failed to create pixel buffer")
        }
        inputPixelBuffer = buffer

        // Decouple running the model from the camera feed since the model will run slower
        Task.detached(priority: .userInitiated) {
            await self.runModel()
        }
        Task {
            await handleCameraFeed()
        }
    }
    
    func handleCameraFeed() async {
        let imageStream = camera.previewStream
        for await image in imageStream {
            lastImage.withLock({ $0 = image })
        }
    }

    func runModel() async {
        try! loadModel()

        let clock = ContinuousClock()
        var durations = [ContinuousClock.Duration]()

        while !Task.isCancelled {
            let image = lastImage.withLock({ $0 })
            if let pixelBuffer = image?.pixelBuffer {
                let duration = await clock.measure {
                    try? await performInference(pixelBuffer)
                }
                durations.append(duration)
            }

            let measureInterval = 100
            if durations.count == measureInterval {
                let total = durations.reduce(Duration(secondsComponent: 0, attosecondsComponent: 0), +)
                let average = total / measureInterval
                print("Average model runtime: \(average.formatted(.units(allowed: [.milliseconds])))")
                durations.removeAll(keepingCapacity: true)
            }

            // Slow down inference to prevent freezing the UI
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func loadModel() throws {
        print("Loading model...")

        let clock = ContinuousClock()
        let start = clock.now

        model = try FastViTMA36F16()

        let duration = clock.now - start
        print("Model loaded (took \(duration.formatted(.units(allowed: [.seconds, .milliseconds]))))")
    }

    func performInference(_ pixelBuffer: CVPixelBuffer) async throws {
        guard let model else {
            return
        }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer).resized(to: targetSize)
        context.render(inputImage, to: inputPixelBuffer)
        let result = try model.prediction(image: inputPixelBuffer)
        let top3 = result.classLabel_probs.sorted { $0.value > $1.value }.prefix(3).map { (label, prob) in
            PredictionResult(label: label, probability: prob)
        }
        Task { @MainActor in
            prediction = top3
        }
    }
}

fileprivate extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

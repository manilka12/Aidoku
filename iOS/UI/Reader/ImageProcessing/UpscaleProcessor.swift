//
//  UpscaleProcessor.swift
//  Aidoku (iOS)
//
//  Created on 19/04/2025.
//

import Foundation
import UIKit
import Nuke

/// Image processor for upscaling images
public class UpscaleProcessor: ImageProcessing {
    
    private let modelType: UpscalerModelType
    private let upscalingFactor: UpscalingFactor
    private let noiseReductionLevel: NoiseReductionLevel
    
    /// Unique identifier for the processor
    public var identifier: String {
        return "io.aidoku.UpscaleProcessor-\(modelType.rawValue)-\(upscalingFactor.rawValue)-\(noiseReductionLevel.rawValue)"
    }
    
    /// Initializes the processor with specific model parameters
    /// - Parameters:
    ///   - modelType: The type of upscaling model to use
    ///   - factor: The upscaling factor
    ///   - noiseLevel: The noise reduction level
    public init(modelType: UpscalerModelType = .waifu2x, 
                factor: UpscalingFactor = .x2, 
                noiseLevel: NoiseReductionLevel = .none) {
        self.modelType = modelType
        self.upscalingFactor = factor
        self.noiseReductionLevel = noiseLevel
    }
    
    /// Checks if the input image needs processing
    /// - Parameter input: Input image
    /// - Returns: True if processing is needed, false otherwise
    public func shouldProcess(_ input: ImageProcessingInput) -> Bool {
        // Only process if:
        // 1. The image exists
        // 2. The image is small enough that upscaling would benefit it
        // 3. The feature is enabled
        guard let image = input.image,
              image.size.width < UIScreen.main.bounds.width * UIScreen.main.scale * 0.8 || // Image is smaller than screen width
              image.size.height < UIScreen.main.bounds.height * UIScreen.main.scale * 0.8, // Image is smaller than screen height
              UserDefaults.standard.bool(forKey: "Reader.upscaleImages") else {
            return false
        }
        return true
    }
    
    /// Process the input image using the configured upscaling model
    /// - Parameter input: Input image
    /// - Returns: Processed image, or nil if processing failed
    public func process(_ input: ImageProcessingInput) -> PlatformImage? {
        guard let image = input.image, shouldProcess(input) else {
            return input.image
        }
        
        // Process the image using our UpscalerService
        // Since the upscaleImage method is async, we need to use a sync wrapper
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: UIImage = image
        
        // Start upscaling in a background task
        Task {
            do {
                // Use UpscalerService to upscale the image
                let upscaled = try await UpscalerService.shared.upscaleImageNow(
                    image,
                    modelType: modelType,
                    factor: upscalingFactor,
                    noiseLevel: noiseReductionLevel
                )
                resultImage = upscaled
            } catch {
                print("Error during image upscaling: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        
        // Wait for the upscaling to complete or timeout
        if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
            print("Upscaling timed out, returning original image")
            // Return original image if upscaling times out
            return image
        }
        
        // For debugging - add a small colored overlay to indicate upscaling is working
        if ProcessInfo.processInfo.environment["DEBUG_UPSCALING"] == "true" {
            return addDebugOverlay(to: resultImage)
        }
        
        return resultImage
    }
    
    /// Add a small colored overlay to the image for debugging
    /// - Parameter image: Original image
    /// - Returns: Image with debugging overlay
    private func addDebugOverlay(to image: UIImage) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        
        // Draw a small indicator in the corner
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let color = UIColor.systemGreen.withAlphaComponent(0.5)
        color.setFill()
        UIRectFill(rect)
        
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
    
    /// Hash value for caching purposes
    /// - Returns: Hash value
    public func hashableIdentifier() -> AnyHashable {
        return identifier
    }
    
    /// Check if this processor is equal to another processor
    /// - Parameter other: Other processor
    /// - Returns: True if processors are equal, false otherwise
    public static func == (lhs: UpscaleProcessor, rhs: UpscaleProcessor) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}
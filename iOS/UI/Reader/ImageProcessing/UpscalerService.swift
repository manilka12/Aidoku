//
//  UpscalerService.swift
//  Aidoku (iOS)
//
//  Created on 19/04/2025.
//

import Foundation
import UIKit

/// Service class for image upscaling operations
class UpscalerService {
    
    // Singleton instance
    static let shared = UpscalerService()
    
    // Private initializer for singleton pattern
    private init() {}
    
    // Default model configuration
    private var defaultModelType: UpscalerModelType = .waifu2x
    private var defaultUpscalingFactor: UpscalingFactor = .x2
    private var defaultNoiseLevel: NoiseReductionLevel = .none
    
    // Processing queue for background operations
    private let processingQueue = DispatchQueue(label: "io.aidoku.upscaler", qos: .userInitiated)
    
    // Cache for upscaled images
    private var cache = NSCache<NSString, UIImage>()
    
    /// Set default model configuration
    /// - Parameters:
    ///   - modelType: Type of upscaling model
    ///   - factor: Upscaling factor
    ///   - noiseLevel: Noise reduction level
    func setDefaultConfig(
        modelType: UpscalerModelType,
        factor: UpscalingFactor,
        noiseLevel: NoiseReductionLevel
    ) {
        defaultModelType = modelType
        defaultUpscalingFactor = factor
        defaultNoiseLevel = noiseLevel
    }
    
    /// Upscale an image using default settings
    /// - Parameter image: Input image
    /// - Returns: Upscaled image, or original if upscaling fails
    func upscaleImage(_ image: UIImage) async -> UIImage {
        return await upscaleImage(
            image,
            modelType: defaultModelType,
            factor: defaultUpscalingFactor,
            noiseLevel: defaultNoiseLevel
        )
    }
    
    /// Upscale an image using specified settings
    /// - Parameters:
    ///   - image: Input image
    ///   - modelType: Type of upscaling model
    ///   - factor: Upscaling factor
    ///   - noiseLevel: Noise reduction level
    /// - Returns: Upscaled image, or original if upscaling fails
    func upscaleImage(
        _ image: UIImage,
        modelType: UpscalerModelType,
        factor: UpscalingFactor,
        noiseLevel: NoiseReductionLevel
    ) async -> UIImage {
        // Generate a cache key based on the image and processing parameters
        let cacheKey = "\(image.hashValue)-\(modelType.rawValue)-\(factor.rawValue)-\(noiseLevel.rawValue)" as NSString
        
        // Check if we have this image in the cache
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        // Get the appropriate model for the requested settings
        guard let model = UpscalerModel.modelFor(
            type: modelType,
            factor: factor,
            noiseLevel: noiseLevel
        ) else {
            return image // Return original image if we can't get a model
        }
        
        // Try to upscale the image
        do {
            let result = try await model.upscaleImage(image)
            // Cache the result
            cache.setObject(result, forKey: cacheKey)
            return result
        } catch {
            print("Image upscaling failed: \(error.localizedDescription)")
            return image // Return original image on failure
        }
    }
    
    /// Upscale an image immediately using specified settings (higher priority)
    /// - Parameters:
    ///   - image: Input image
    ///   - modelType: Type of upscaling model
    ///   - factor: Upscaling factor
    ///   - noiseLevel: Noise reduction level
    /// - Returns: Upscaled image, or original if upscaling fails
    /// - Throws: Any error encountered during upscaling
    func upscaleImageNow(
        _ image: UIImage,
        modelType: UpscalerModelType,
        factor: UpscalingFactor,
        noiseLevel: NoiseReductionLevel
    ) async throws -> UIImage {
        // Generate a cache key based on the image and processing parameters
        let cacheKey = "\(image.hashValue)-\(modelType.rawValue)-\(factor.rawValue)-\(noiseLevel.rawValue)" as NSString
        
        // Check if we have this image in the cache
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        // Get the appropriate model for the requested settings
        guard let model = UpscalerModel.modelFor(
            type: modelType,
            factor: factor,
            noiseLevel: noiseLevel
        ) else {
            throw NSError(domain: "io.aidoku.upscaler", code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "No model available for upscaling"])
        }
        
        // Try to upscale the image with higher task priority
        return try await withTaskGroup(of: UIImage.self, returning: UIImage.self) { group in
            group.addTask(priority: .userInitiated) {
                do {
                    // Attempt to upscale the image
                    let result = try await model.upscaleImage(image)
                    // Cache the result
                    self.cache.setObject(result, forKey: cacheKey)
                    return result
                } catch {
                    print("Image upscaling failed: \(error.localizedDescription)")
                    throw error
                }
            }
            
            // Return the first (and only) result or the original image if there's an error
            do {
                if let result = try await group.next() {
                    return result
                }
            } catch {
                throw error
            }
            
            return image
        }
    }
    
    /// Preload upscaling for an image in the background
    /// - Parameters:
    ///   - image: The image to preload upscaling for
    ///   - modelType: Type of upscaling model
    ///   - factor: Upscaling factor
    ///   - noiseLevel: Noise reduction level
    func preloadUpscale(
        _ image: UIImage,
        modelType: UpscalerModelType = .waifu2x,
        factor: UpscalingFactor = .x2,
        noiseLevel: NoiseReductionLevel = .none
    ) {
        // Generate a cache key based on the image and processing parameters
        let cacheKey = "\(image.hashValue)-\(modelType.rawValue)-\(factor.rawValue)-\(noiseLevel.rawValue)" as NSString
        
        // If it's already in the cache, don't process again
        guard cache.object(forKey: cacheKey) == nil else {
            return
        }
        
        // Process in background with lower priority
        Task(priority: .background) {
            let result = await upscaleImage(image, modelType: modelType, factor: factor, noiseLevel: noiseLevel)
            // Cache is handled in upscaleImage method
        }
    }
    
    /// Clear the upscaling cache
    func clearCache() {
        cache.removeAllObjects()
    }
}
//
//  UpscalerModel.swift
//  Aidoku (iOS)
//
//  Created on 19/04/2025.
//

import Foundation
import CoreML
import UIKit

/// Represents the different types of upscaling models available
enum UpscalerModelType: String, CaseIterable {
    case waifu2x = "waifu2x"
    case esrgan = "esrgan"
    
    var displayName: String {
        switch self {
        case .waifu2x:
            return "Waifu2x"
        case .esrgan:
            return "ESRGAN"
        }
    }
}

/// Represents the upscaling factor
enum UpscalingFactor: Int, CaseIterable {
    case x1 = 1
    case x2 = 2
    
    var displayName: String {
        return "×\(self.rawValue)"
    }
}

/// Represents the noise reduction level
enum NoiseReductionLevel: Int, CaseIterable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    
    var displayName: String {
        switch self {
        case .none:
            return NSLocalizedString("NONE", comment: "")
        case .low:
            return NSLocalizedString("LOW", comment: "")
        case .medium:
            return NSLocalizedString("MEDIUM", comment: "")
        case .high:
            return NSLocalizedString("HIGH", comment: "")
        }
    }
}

/// Protocol for upscaling models
protocol UpscalerModelProtocol {
    var modelType: UpscalerModelType { get }
    var upscalingFactor: UpscalingFactor { get }
    var noiseReductionLevel: NoiseReductionLevel { get }
    
    func upscaleImage(_ image: UIImage) async throws -> UIImage
}

/// Base class for upscaler models
class UpscalerModel {
    static let defaultTileSize: Int = 240
    static let defaultOverlap: Int = 16
    
    class func modelFor(type: UpscalerModelType, 
                        factor: UpscalingFactor, 
                        noiseLevel: NoiseReductionLevel) -> UpscalerModelProtocol? {
        switch type {
        case .waifu2x:
            return Waifu2xModel(upscalingFactor: factor, noiseReductionLevel: noiseLevel)
        case .esrgan:
            // Not implemented yet
            return nil
        }
    }
}

/// Waifu2x implementation of upscaler model
class Waifu2xModel: UpscalerModelProtocol {
    let modelType: UpscalerModelType = .waifu2x
    let upscalingFactor: UpscalingFactor
    let noiseReductionLevel: NoiseReductionLevel
    
    private var model: MLModel?
    private let tileSize: Int
    private let tileOverlap: Int
    
    init(upscalingFactor: UpscalingFactor, 
         noiseReductionLevel: NoiseReductionLevel, 
         tileSize: Int = UpscalerModel.defaultTileSize,
         tileOverlap: Int = UpscalerModel.defaultOverlap) {
        self.upscalingFactor = upscalingFactor
        self.noiseReductionLevel = noiseReductionLevel
        self.tileSize = tileSize
        self.tileOverlap = tileOverlap
        
        // Try to load the appropriate CoreML model
        loadModel()
    }
    
    private func loadModel() {
        // Construct the model name based on the settings
        let modelName = "waifu2x_noise\(noiseReductionLevel.rawValue)_scale\(upscalingFactor.rawValue)x"
        
        // Try to load the model
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodel", subdirectory: "UpscaleModels") else {
            print("Could not find model file: \(modelName).mlmodel")
            return
        }
        
        do {
            // Compile the model if needed
            let compiledModelURL = try MLModel.compileModel(at: modelURL)
            
            // Load the compiled model
            model = try MLModel(contentsOf: compiledModelURL)
        } catch {
            print("Error loading model \(modelName): \(error.localizedDescription)")
        }
    }
    
    func upscaleImage(_ image: UIImage) async throws -> UIImage {
        guard let model = model else {
            // If model isn't available, just return the original image
            print("No model available for upscaling, returning original image")
            return image
        }
        
        // Calculate target size based on upscaling factor
        let targetSize = CGSize(
            width: image.size.width * CGFloat(upscalingFactor.rawValue),
            height: image.size.height * CGFloat(upscalingFactor.rawValue)
        )
        
        // Check if the image is too large to process at once
        let maxPixels = 1024 * 1024 // 1 million pixels threshold
        let imagePixels = image.size.width * image.size.height
        
        if imagePixels <= maxPixels {
            // Small image - process in one go
            return try await processWholeImage(image, targetSize: targetSize)
        } else {
            // Large image - process in tiles
            return try await processTiledImage(image, targetSize: targetSize)
        }
    }
    
    /// Process a small image in one go
    private func processWholeImage(_ image: UIImage, targetSize: CGSize) async throws -> UIImage {
        guard let model = model,
              let cgImage = image.cgImage else {
            return image
        }
        
        // Create MLFeatureProvider from the image
        let imageConstraint = MLImageConstraint(pixelsHigh: Int(image.size.height), 
                                               pixelsWide: Int(image.size.width))
        guard let mlImage = try? MLFeatureValue(cgImage: cgImage, constraint: imageConstraint) else {
            print("Failed to create MLFeatureValue from image")
            return image
        }
        
        // Create input for the model
        let featureProvider = try MLDictionaryFeatureProvider(dictionary: ["input": mlImage])
        
        // Run inference
        guard let result = try? model.prediction(from: featureProvider) else {
            print("Model prediction failed")
            return image
        }
        
        // Extract output image
        guard let outputFeatureValue = result.featureValue(for: "output"),
              let outputImage = outputFeatureValue.imageBufferValue,
              let cgOutputImage = convertCIImageToCGImage(CIImage(cvPixelBuffer: outputImage)) else {
            print("Failed to extract output image from model result")
            return image
        }
        
        // Create final upscaled UIImage
        return UIImage(cgImage: cgOutputImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    /// Process a large image by splitting it into tiles and upscaling each tile
    private func processTiledImage(_ image: UIImage, targetSize: CGSize) async throws -> UIImage {
        guard let cgImage = image.cgImage else {
            return image
        }
        
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let targetWidth = Int(targetSize.width)
        let targetHeight = Int(targetSize.height)
        
        // Create context for the final upscaled image
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                     width: targetWidth,
                                     height: targetHeight,
                                     bitsPerComponent: 8,
                                     bytesPerRow: targetWidth * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("Failed to create graphics context")
            return image
        }
        
        // Calculate the number of tiles
        let cols = (width + tileSize - 2 * tileOverlap - 1) / (tileSize - 2 * tileOverlap)
        let rows = (height + tileSize - 2 * tileOverlap - 1) / (tileSize - 2 * tileOverlap)
        
        // Create a progress tracker
        let totalTiles = cols * rows
        var processedTiles = 0
        
        // Process each tile
        for row in 0..<rows {
            for col in 0..<cols {
                // Report progress
                processedTiles += 1
                let progress = Double(processedTiles) / Double(totalTiles)
                print("Upscaling progress: \(Int(progress * 100))%")
                
                // Calculate tile position
                let x = col * (tileSize - 2 * tileOverlap)
                let y = row * (tileSize - 2 * tileOverlap)
                let tileWidth = min(tileSize, width - x)
                let tileHeight = min(tileSize, height - y)
                
                // Skip empty tiles
                if tileWidth <= 0 || tileHeight <= 0 {
                    continue
                }
                
                // Extract the tile image
                guard let tileCGImage = cgImage.cropping(to: CGRect(x: x, y: y, width: tileWidth, height: tileHeight)) else {
                    continue
                }
                let tileImage = UIImage(cgImage: tileCGImage)
                
                // Process the tile
                let processedTile = try await processWholeImage(tileImage, targetSize: CGSize(
                    width: tileWidth * upscalingFactor.rawValue,
                    height: tileHeight * upscalingFactor.rawValue
                ))
                
                guard let processedCGImage = processedTile.cgImage else {
                    continue
                }
                
                // Calculate the position in the output image where this tile should go
                let destX = x * upscalingFactor.rawValue
                let destY = y * upscalingFactor.rawValue
                
                // Draw the processed tile in the output context
                context.draw(processedCGImage, in: CGRect(
                    x: destX,
                    y: destY,
                    width: tileWidth * upscalingFactor.rawValue,
                    height: tileHeight * upscalingFactor.rawValue
                ))
            }
        }
        
        // Create the final image from the context
        guard let finalCGImage = context.makeImage() else {
            return image
        }
        
        return UIImage(cgImage: finalCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    /// Utility method to convert CIImage to CGImage
    private func convertCIImageToCGImage(_ ciImage: CIImage) -> CGImage? {
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
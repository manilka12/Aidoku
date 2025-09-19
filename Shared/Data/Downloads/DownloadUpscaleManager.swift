//
//  DownloadUpscaleManager.swift
//  Aidoku
//
//  Created by Assistant on 9/19/25.
//

import Foundation
import CoreGraphics
import UIKit

// Manages automatic upscaling of downloaded manga images
actor DownloadUpscaleManager {
    static let shared = DownloadUpscaleManager()
    
    private var processingQueue: Set<String> = []
    private var failedQueue: Set<String> = []
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
    private var retryCount: [String: Int] = [:]
    private let maxRetries = 3
    
    // User setting keys
    static let autoUpscaleEnabledKey = "Downloads.autoUpscaleEnabled"
    static let autoUpscaleMaxSizeKey = "Downloads.autoUpscaleMaxSize"
    static let autoUpscaleQualityPreservationKey = "Downloads.autoUpscaleQualityPreservation"
    static let autoUpscaleJPEGQualityKey = "Downloads.autoUpscaleJPEGQuality"
    
    private init() {}
    
    // Check if auto upscaling is enabled
    nonisolated var isAutoUpscaleEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoUpscaleEnabledKey)
    }
    
    // Get max file size for auto upscaling (in bytes)
    nonisolated var maxAutoUpscaleSize: Int {
        let defaultSize = 5 * 1024 * 1024 // 5MB default
        let storedSize = UserDefaults.standard.integer(forKey: Self.autoUpscaleMaxSizeKey)
        if storedSize == 0 {
            // Set default value if not set
            UserDefaults.standard.set(defaultSize, forKey: Self.autoUpscaleMaxSizeKey)
            return defaultSize
        }
        return storedSize
    }
    
    // Check if quality preservation is enabled (keeps original as backup)
    nonisolated var shouldPreserveOriginal: Bool {
        UserDefaults.standard.bool(forKey: Self.autoUpscaleQualityPreservationKey)
    }
    
    // Get JPEG quality setting (0.1 to 1.0)
    nonisolated var jpegQualitySetting: Double {
        let storedQuality = UserDefaults.standard.double(forKey: Self.autoUpscaleJPEGQualityKey)
        if storedQuality == 0.0 {
            // Set default value: 0.90 for very high quality
            UserDefaults.standard.set(0.90, forKey: Self.autoUpscaleJPEGQualityKey)
            return 0.90
        }
        return max(0.1, min(1.0, storedQuality)) // Clamp between 0.1 and 1.0
    }
    
    // Queue a chapter for background upscaling
    func queueChapterForUpscaling(_ chapter: Chapter) async {
        let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
        
        guard isAutoUpscaleEnabled,
              !processingQueue.contains(chapterKey),
              ModelManager.shared.getEnabledModelFileName() != nil else {
            return
        }
        
        processingQueue.insert(chapterKey)
        
        // Start processing if not already running
        if !isProcessing {
            await startProcessingQueue()
        }
    }
    
    // Start processing the upscaling queue
    private func startProcessingQueue() async {
        guard !isProcessing else { return }
        
        isProcessing = true
        processingTask = Task {
            await processNextInQueue()
        }
    }
    
    // Process the next chapter in queue
    private func processNextInQueue() async {
        guard let nextChapterKey = processingQueue.first else {
            isProcessing = false
            return
        }
        
        processingQueue.remove(nextChapterKey)
        
        // Parse chapter key
        let components = nextChapterKey.split(separator: "_")
        guard components.count == 3 else {
            await processNextInQueue()
            return
        }
        
        let chapter = Chapter(
            sourceId: String(components[0]),
            id: String(components[2]),
            mangaId: String(components[1]),
            title: nil,
            sourceOrder: -1
        )
        
        await upscaleChapterImages(chapter)
        
        // Continue processing
        await processNextInQueue()
    }
    
    // Upscale all images in a chapter
    private func upscaleChapterImages(_ chapter: Chapter) async {
        let cache = await MainActor.run { DownloadCache() }
        let chapterDirectory = await cache.directory(for: chapter)
        let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
        
        guard chapterDirectory.exists else { 
            LogManager.logger.warn("Chapter directory not found for upscaling: \(chapterKey)")
            return 
        }
        
        // Check if we have enough storage space (estimate: upscaled images can be 4x larger)
        let availableSpace = FileManager.default.availableDiskSpace
        let chapterSize = chapterDirectory.directorySize
        let estimatedUpscaledSize = chapterSize * 4
        
        guard availableSpace > estimatedUpscaledSize + (100 * 1024 * 1024) else { // Keep 100MB buffer
            LogManager.logger.error("Insufficient disk space for upscaling chapter \(chapterKey). Need: \(estimatedUpscaledSize), Available: \(availableSpace)")
            return
        }

        let imageFiles = chapterDirectory.contents.filter { url in
            let allowedExtensions = Set(["jpg", "jpeg", "png", "webp", "gif"])
            return allowedExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasSuffix(".original")
        }
        
        guard !imageFiles.isEmpty else {
            LogManager.logger.info("No images found to upscale in chapter \(chapterKey)")
            return
        }
        
        // Filter to only process unupscaled images (enables resume functionality)
        let unupscaledImages = Self.getUnupscaledImages(in: chapterDirectory)
        
        guard !unupscaledImages.isEmpty else {
            LogManager.logger.info("All images already upscaled in chapter \(chapterKey)")
            // Mark as complete if all images are already upscaled
            Self.markChapterAsFullyUpscaled(at: chapterDirectory)
            return
        }
        
        LogManager.logger.info("Starting upscaling: \(unupscaledImages.count)/\(imageFiles.count) images remaining in chapter \(chapterKey)")
        
        var successCount = 0
        var failureCount = 0
        
        for imageFile in unupscaledImages {
            let success = await upscaleImage(at: imageFile)
            if success {
                successCount += 1
            } else {
                failureCount += 1
            }
            
            // Add small delay to prevent overwhelming the system
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        if failureCount > 0 {
            LogManager.logger.warn("Completed upscaling for chapter \(chapterKey): \(successCount) success, \(failureCount) failures")
            
            // Add to failed queue if too many failures
            if failureCount > imageFiles.count / 2 {
                failedQueue.insert(chapterKey)
            }
        }
        
        // Check if ALL images in the chapter are now upscaled (not just current session)
        let totalUpscaled = imageFiles.count - Self.getUnupscaledImages(in: chapterDirectory).count
        if totalUpscaled == imageFiles.count {
            // Mark chapter as fully upscaled if all images are now upscaled
            Self.markChapterAsFullyUpscaled(at: chapterDirectory)
            LogManager.logger.info("All images in chapter \(chapterKey) are now upscaled - marked as complete")
        } else {
            LogManager.logger.info("Chapter \(chapterKey) upscaling session complete: \(totalUpscaled)/\(imageFiles.count) images upscaled")
        }
        
        // Clear retry count on successful completion
        retryCount.removeValue(forKey: chapterKey)
    }
    
    // Upscale a single image file
    private func upscaleImage(at imageURL: URL) async -> Bool {
        // Skip images that are already upscaled
        if isImageUpscaled(imageURL) {
            LogManager.logger.debug("Skipping already upscaled image: \(imageURL.lastPathComponent)")
            return true
        }
        
        guard let fileData = try? Data(contentsOf: imageURL),
              fileData.count <= maxAutoUpscaleSize else {
            LogManager.logger.debug("Skipping upscale for \(imageURL.lastPathComponent): file too large or unreadable")
            return false
        }
        
        guard let originalImage = UIImage(data: fileData),
              let cgImage = originalImage.cgImage else {
            LogManager.logger.warn("Could not decode image: \(imageURL.lastPathComponent)")
            return false
        }
        
        // Skip if image is already large enough
        let maxDimension = cgImage.width // Changed from max(cgImage.width, cgImage.height) to just width
        let upscaleThreshold = UserDefaults.standard.integer(forKey: "Reader.upscaleMaxHeight") // Note: keeping same key for compatibility
        if maxDimension >= upscaleThreshold {
            LogManager.logger.debug("Skipping upscale for \(imageURL.lastPathComponent): width already large enough (\(maxDimension)px)")
            return true // Not a failure, just skipped
        }
        
        do {
            // Get the enabled model
            guard let model = try await ModelManager.shared.getEnabledModel() else {
                LogManager.logger.warn("No upscaling model available for auto-upscale")
                return false
            }
            
            // Process the image
            guard let upscaledCGImage = await model.process(cgImage) else {
                LogManager.logger.error("Failed to upscale image: \(imageURL.lastPathComponent)")
                return false
            }
            
            // Create backup if quality preservation is enabled
            if shouldPreserveOriginal {
                let backupURL = imageURL.appendingPathExtension("original")
                if !backupURL.exists {
                    try? FileManager.default.copyItem(at: imageURL, to: backupURL)
                }
            }
            
            // Save upscaled image with intelligent compression strategy
            let upscaledImage = UIImage(cgImage: upscaledCGImage)
            let originalExtension = imageURL.pathExtension.lowercased()
            
            var imageData: Data?
            var finalImageURL = imageURL
            var compressionStrategy = "unknown"
            
            if originalExtension == "png" {
                // Try PNG optimization first (respecting original format)
                imageData = upscaledImage.pngData()
                compressionStrategy = "PNG (native)"
                
                // If PNG result is extremely large (>8MB), offer JPEG alternative
                if let pngData = imageData, pngData.count > 8 * 1024 * 1024 {
                    // Try JPEG compression as alternative
                    if let jpegData = upscaledImage.jpegData(compressionQuality: jpegQualitySetting) {
                        let pngSize = pngData.count
                        let jpegSize = jpegData.count
                        let savings = Double(pngSize - jpegSize) / Double(pngSize) * 100
                        
                        // If JPEG saves significant space (>50%), use it
                        if savings > 50.0 {
                            imageData = jpegData
                            finalImageURL = imageURL.deletingPathExtension().appendingPathExtension("jpg")
                            compressionStrategy = "PNG→JPEG (saved \(Int(savings))% at \(Int(jpegQualitySetting*100))% quality)"
                            
                            // Remove original PNG file after successful conversion
                            if imageURL.exists {
                                try? FileManager.default.removeItem(at: imageURL)
                            }
                            
                            LogManager.logger.info("Large PNG converted to JPEG: \(ByteCountFormatter.string(fromByteCount: Int64(pngSize), countStyle: .binary)) → \(ByteCountFormatter.string(fromByteCount: Int64(jpegSize), countStyle: .binary))")
                        }
                    }
                }
            } else {
                // For JPEG and other formats, use optimized JPEG compression
                imageData = upscaledImage.jpegData(compressionQuality: jpegQualitySetting)
                compressionStrategy = "JPEG (\(Int(jpegQualitySetting*100))% quality)"
            }
            
            guard let data = imageData else {
                LogManager.logger.error("Failed to encode upscaled image: \(imageURL.lastPathComponent)")
                return false
            }
            
            try data.write(to: finalImageURL)
            
            // Mark image as upscaled with metadata for tracking
            Self.markImageAsUpscaled(at: finalImageURL, quality: jpegQualitySetting, originalSize: Int64(fileData.count), upscaledSize: Int64(data.count))
            
            let compressionRatio = Double(fileData.count) / Double(data.count)
            LogManager.logger.debug("Successfully upscaled: \(finalImageURL.lastPathComponent) using \(compressionStrategy) (original: \(ByteCountFormatter.string(fromByteCount: Int64(fileData.count), countStyle: .binary)) → final: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)), ratio: \(String(format: "%.1fx", compressionRatio)))")
            return true
            
        } catch {
            LogManager.logger.error("Error during auto-upscale of \(imageURL.lastPathComponent): \(error)")
            return false
        }
    }
    
    // Stop all processing
    func stopProcessing() async {
        isProcessing = false
        processingTask?.cancel()
        processingTask = nil
        processingQueue.removeAll()
    }
    
    // Resume upscaling for any incomplete chapters on app startup
    func resumeIncompleteUpscaling() async {
        guard isAutoUpscaleEnabled else { return }
        
        LogManager.logger.info("Scanning for incomplete upscaling tasks...")
        
        let downloadManager = await MainActor.run { DownloadManager.shared }
        let downloadedManga = await downloadManager.getAllDownloadedManga()
        
        var incompleteCount = 0
        for mangaInfo in downloadedManga {
            let chapters = await downloadManager.getDownloadedChapters(for: mangaInfo)
            for chapterInfo in chapters {
                // Convert DownloadedChapterInfo to Chapter
                let chapter = Chapter(
                    sourceId: mangaInfo.sourceId,
                    id: chapterInfo.chapterId,
                    mangaId: mangaInfo.mangaId,
                    title: chapterInfo.title,
                    sourceOrder: -1
                )
                
                let cache = await MainActor.run { DownloadCache() }
                let chapterDirectory = await cache.directory(for: chapter)
                
                if Self.hasUnupscaledImages(in: chapterDirectory) {
                    incompleteCount += 1
                    await queueChapterForUpscaling(chapter)
                    
                    let progress = Self.getUpscalingProgress(for: chapterDirectory)
                    LogManager.logger.debug("Resuming upscaling for chapter \(chapter.title ?? "Unknown"): \(Int(progress * 100))% complete")
                }
            }
        }
        
        if incompleteCount > 0 {
            LogManager.logger.info("Found \(incompleteCount) chapters with incomplete upscaling, resuming...")
        } else {
            LogManager.logger.info("No incomplete upscaling tasks found")
        }
    }
    
    // MARK: - Upscale Detection Methods
    
    // Check if an image has already been upscaled
    nonisolated func isImageUpscaled(_ imageURL: URL) -> Bool {
        let metadataURL = getMetadataURL(for: imageURL)
        return metadataURL.exists
    }
    
    // Save metadata when an image is upscaled
    private func saveUpscaleMetadata(for imageURL: URL, originalSize: Int, upscaledSize: Int) async throws {
        let metadata = [
            "upscaled": true,
            "timestamp": Date().timeIntervalSince1970,
            "originalSize": originalSize,
            "upscaledSize": upscaledSize,
            "version": "1.0"
        ] as [String: Any]
        
        let metadataURL = getMetadataURL(for: imageURL)
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [])
        try data.write(to: metadataURL)
    }
    
    // Get metadata file URL for an image
    private nonisolated func getMetadataURL(for imageURL: URL) -> URL {
        let filename = imageURL.deletingPathExtension().lastPathComponent
        return imageURL.deletingLastPathComponent().appendingPathComponent(".\(filename).upscale")
    }
    
    // Get current queue status
    func getQueueStatus() async -> (isProcessing: Bool, queueCount: Int) {
        return (isProcessing, processingQueue.count)
    }
    
    // Queue all downloaded chapters for upscaling (for manual upscaling)
    func queueAllDownloadsForUpscaling() async {
        guard isAutoUpscaleEnabled || ModelManager.shared.getEnabledModelFileName() != nil else {
            LogManager.logger.warn("Cannot queue downloads for upscaling: no model enabled")
            return
        }
        
        let downloadManager = await MainActor.run { DownloadManager.shared }
        let downloadedManga = await downloadManager.getAllDownloadedManga()
        var chaptersQueued = 0
        
        for mangaInfo in downloadedManga {
            let chapters = await downloadManager.getDownloadedChapters(for: mangaInfo)
            for chapterInfo in chapters {
                // Convert DownloadedChapterInfo to Chapter
                let chapter = Chapter(
                    sourceId: mangaInfo.sourceId,
                    id: chapterInfo.chapterId,
                    mangaId: mangaInfo.mangaId,
                    title: chapterInfo.title,
                    sourceOrder: -1
                )
                
                let cache = await MainActor.run { DownloadCache() }
                let chapterDirectory = await cache.directory(for: chapter)
                
                // Only queue chapters that have unupscaled images (smart resume logic)
                if Self.hasUnupscaledImages(in: chapterDirectory) {
                    let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
                    if !processingQueue.contains(chapterKey) {
                        processingQueue.insert(chapterKey)
                        chaptersQueued += 1
                        
                        let progress = Self.getUpscalingProgress(for: chapterDirectory)
                        LogManager.logger.debug("Queued chapter \(chapter.title ?? "Unknown") for upscaling: \(Int(progress * 100))% complete")
                    }
                } else {
                    LogManager.logger.debug("Skipping chapter \(chapter.title ?? "Unknown"): already fully upscaled")
                }
            }
        }
        
        LogManager.logger.info("Queued \(chaptersQueued) chapters for manual upscaling (with incomplete images)")
        
        // Start processing if not already running
        if !isProcessing && !processingQueue.isEmpty {
            await startProcessingQueue()
        }
    }
}

// MARK: - FileManager Extensions for Robustness
private extension FileManager {
    var availableDiskSpace: Int64 {
        guard let attributes = try? attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return freeSize.int64Value
    }
}

private extension URL {
    var directorySize: Int64 {
        guard let enumerator = FileManager.default.enumerator(at: self, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }
}

// MARK: - Individual Image Tracking Extensions
extension DownloadUpscaleManager {
    
    /// Check if a specific image has been upscaled
    static func isImageUpscaled(at imagePath: URL) -> Bool {
        let upscaleMarkerPath = imagePath.appendingPathExtension("upscaled")
        return FileManager.default.fileExists(atPath: upscaleMarkerPath.path)
    }
    
    /// Mark a specific image as upscaled
    static func markImageAsUpscaled(at imagePath: URL, quality: Double = 0.90, originalSize: Int64 = 0, upscaledSize: Int64 = 0) {
        let upscaleMarkerPath = imagePath.appendingPathExtension("upscaled")
        let metadata = """
        upscaled
        quality: \(quality)
        original_size: \(originalSize)
        upscaled_size: \(upscaledSize)
        timestamp: \(Date().timeIntervalSince1970)
        """
        try? metadata.write(to: upscaleMarkerPath, atomically: true, encoding: .utf8)
    }
    
    /// Get all image files in a directory that need upscaling
    static func getUnupscaledImages(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif"])
        let imageFiles = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return imageExtensions.contains(ext) && !url.lastPathComponent.hasSuffix(".original")
        }
        
        return imageFiles.filter { !isImageUpscaled(at: $0) }
    }
    
    /// Check if a downloaded chapter has any unupscaled images
    static func hasUnupscaledImages(in chapterDirectory: URL) -> Bool {
        return !getUnupscaledImages(in: chapterDirectory).isEmpty
    }
    
    /// Get upscaling progress for a chapter (0.0 to 1.0)
    static func getUpscalingProgress(for chapterDirectory: URL) -> Double {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: chapterDirectory, includingPropertiesForKeys: nil) else {
            return 0.0
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif"])
        let imageFiles = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return imageExtensions.contains(ext) && !url.lastPathComponent.hasSuffix(".original")
        }
        
        guard !imageFiles.isEmpty else { return 1.0 } // No images = complete
        
        let upscaledCount = imageFiles.filter { isImageUpscaled(at: $0) }.count
        return Double(upscaledCount) / Double(imageFiles.count)
    }
    
    // MARK: - Chapter-Level Completion Tracking
    
    /// Mark a chapter as fully upscaled
    static func markChapterAsFullyUpscaled(at chapterDirectory: URL) {
        let finishedMarkerPath = chapterDirectory.appendingPathComponent("finished.upscale")
        let metadata = """
        chapter_fully_upscaled
        completed_timestamp: \(Date().timeIntervalSince1970)
        """
        try? metadata.write(to: finishedMarkerPath, atomically: true, encoding: .utf8)
    }
    
    /// Check if a chapter is fully upscaled
    static func isChapterFullyUpscaled(at chapterDirectory: URL) -> Bool {
        let finishedMarkerPath = chapterDirectory.appendingPathComponent("finished.upscale")
        return FileManager.default.fileExists(atPath: finishedMarkerPath.path)
    }
    
    /// Remove chapter completion marker (for reprocessing)
    static func removeChapterCompletionMarker(at chapterDirectory: URL) {
        let finishedMarkerPath = chapterDirectory.appendingPathComponent("finished.upscale")
        try? FileManager.default.removeItem(at: finishedMarkerPath)
    }
    
    /// Get comprehensive upscaling status for a chapter
    static func getChapterUpscalingStatus(for chapterDirectory: URL) -> ChapterUpscalingStatus {
        // First check if the directory exists (chapter must be downloaded)
        guard FileManager.default.fileExists(atPath: chapterDirectory.path) else {
            return .notStarted
        }
        
        // Check if chapter is marked as fully complete
        if isChapterFullyUpscaled(at: chapterDirectory) {
            return .fullyUpscaled
        }
        
        // Get current progress
        let progress = getUpscalingProgress(for: chapterDirectory)
        
        if progress == 0.0 {
            return .notStarted
        } else if progress == 1.0 {
            // All images are upscaled but not marked as complete yet
            // Mark it as complete now
            markChapterAsFullyUpscaled(at: chapterDirectory)
            return .fullyUpscaled
        } else {
            return .partiallyUpscaled(progress: progress)
        }
        }
    }
}

/// Represents the upscaling status of a chapter
enum ChapterUpscalingStatus: Equatable {
    case notStarted
    case partiallyUpscaled(progress: Double)
    case fullyUpscaled
    
    var isComplete: Bool {
        if case .fullyUpscaled = self {
            return true
        }
        return false
    }
    
    var progressPercentage: Int {
        switch self {
        case .notStarted:
            return 0
        case .partiallyUpscaled(let progress):
            return Int(progress * 100)
        case .fullyUpscaled:
            return 100
        }
    }
}
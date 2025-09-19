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
        
        LogManager.logger.info("Starting auto-upscale for chapter \(chapterKey): \(imageFiles.count) images")
        
        var successCount = 0
        var failureCount = 0
        
        for imageFile in imageFiles {
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
        } else {
            LogManager.logger.info("Successfully upscaled all images in chapter \(chapterKey)")
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
            
            // Save upscaled image with compression to reduce file size
            let upscaledImage = UIImage(cgImage: upscaledCGImage)
            
            // Choose format and compression based on original file extension
            let imageData: Data?
            if imageURL.pathExtension.lowercased() == "png" {
                // For PNG, use moderate compression
                imageData = upscaledImage.pngData()
            } else {
                // For JPEG, use high quality compression (0.85 instead of 0.95 to reduce size)
                imageData = upscaledImage.jpegData(compressionQuality: 0.85)
            }
            
            guard let data = imageData else {
                LogManager.logger.error("Failed to encode upscaled image: \(imageURL.lastPathComponent)")
                return false
            }
            
            try data.write(to: imageURL)
            
            // Save metadata to indicate this image was upscaled
            try await saveUpscaleMetadata(for: imageURL, originalSize: fileData.count, upscaledSize: data.count)
            
            LogManager.logger.debug("Successfully upscaled: \(imageURL.lastPathComponent) (size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)))")
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
        
        let downloadedManga = await DownloadManager.shared.getAllDownloadedManga()
        var chaptersQueued = 0
        
        for manga in downloadedManga {
            let allChapters = await CoreDataManager.shared.getChapters(sourceId: manga.sourceId, mangaId: manga.id)
            
            // Filter chapters that are downloaded using async loop
            var downloadedChapters: [Chapter] = []
            for chapter in allChapters {
                if await DownloadManager.shared.isChapterDownloaded(chapter: chapter) {
                    downloadedChapters.append(chapter)
                }
            }
            
            for chapter in downloadedChapters {
                let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
                if !processingQueue.contains(chapterKey) {
                    processingQueue.insert(chapterKey)
                    chaptersQueued += 1
                }
            }
        }
        
        LogManager.logger.info("Queued \(chaptersQueued) chapters for manual upscaling")
        
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
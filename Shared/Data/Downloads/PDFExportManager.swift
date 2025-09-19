//
//  PDFExportManager.swift
//  Aidoku
//
//  Created by Assistant on 9/20/25.
//

import Foundation
import CoreGraphics
import UIKit
import PDFKit

// Manages PDF export of downloaded manga chapters
actor PDFExportManager {
    static let shared = PDFExportManager()
    
    private var exportingChapters: Set<String> = []
    
    private init() {}
    
    // Export a single chapter to PDF
    func exportChapter(_ chapter: Chapter, to outputURL: URL) async throws {
        let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
        
        guard !exportingChapters.contains(chapterKey) else {
            throw PDFExportError.alreadyExporting
        }
        
        exportingChapters.insert(chapterKey)
        defer { exportingChapters.remove(chapterKey) }
        
        LogManager.logger.info("Starting PDF export for chapter: \(chapter.title ?? "Unknown")")
        
        let cache = await MainActor.run { DownloadCache() }
        let chapterDirectory = await cache.directory(for: chapter)
        
        guard chapterDirectory.exists else {
            throw PDFExportError.chapterNotDownloaded
        }
        
        // Get all image files in the chapter directory
        let imageFiles = getImageFiles(in: chapterDirectory)
        
        guard !imageFiles.isEmpty else {
            throw PDFExportError.noImagesFound
        }
        
        // Create PDF document
        let pdfDocument = PDFDocument()
        var pageIndex = 0
        
        for imageURL in imageFiles {
            autoreleasepool {
                if let image = UIImage(contentsOfFile: imageURL.path),
                   let pdfPage = createPDFPage(from: image) {
                    pdfDocument.insert(pdfPage, at: pageIndex)
                    pageIndex += 1
                }
            }
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw PDFExportError.failedToCreatePDF
        }
        
        // Save PDF
        guard pdfDocument.write(to: outputURL) else {
            throw PDFExportError.failedToSavePDF
        }
        
        LogManager.logger.info("Successfully exported chapter to PDF: \(outputURL.lastPathComponent) (\(pdfDocument.pageCount) pages)")
    }
    
    // Export multiple chapters to separate PDFs
    func exportChapters(_ chapters: [Chapter], to outputDirectory: URL) async throws -> [URL] {
        var exportedFiles: [URL] = []
        
        // Ensure output directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        for chapter in chapters {
            let sanitizedTitle = sanitizeFilename(chapter.title ?? "Chapter_\(chapter.id)")
            let outputURL = outputDirectory.appendingPathComponent("\(sanitizedTitle).pdf")
            
            do {
                try await exportChapter(chapter, to: outputURL)
                exportedFiles.append(outputURL)
            } catch {
                LogManager.logger.error("Failed to export chapter \(chapter.title ?? "Unknown"): \(error)")
                // Continue with other chapters even if one fails
            }
        }
        
        return exportedFiles
    }
    
    // Get status of export operations
    func isExporting(chapter: Chapter) async -> Bool {
        let chapterKey = "\(chapter.sourceId)_\(chapter.mangaId)_\(chapter.id)"
        return exportingChapters.contains(chapterKey)
    }
    
    // MARK: - Private Helper Methods
    
    private func getImageFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif"])
        let imageFiles = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return imageExtensions.contains(ext) && !url.lastPathComponent.hasSuffix(".original")
        }
        
        // Sort files naturally (001.jpg, 002.jpg, etc.)
        return imageFiles.sorted { url1, url2 in
            url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent) == .orderedAscending
        }
    }
    
    private func createPDFPage(from image: UIImage) -> PDFPage? {
        // Create page with image size
        var pageRect = CGRect(origin: .zero, size: image.size)
        
        // Create graphics context for PDF
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            return nil
        }
        
        context.beginPDFPage([:])
        
        // Draw image to fill the page
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: pageRect)
        }
        
        context.endPDFPage()
        context.closePDF()
        
        // Create PDFPage from the context data
        guard let pdfDocument = PDFDocument(data: pdfData as Data),
              let page = pdfDocument.page(at: 0) else {
            return nil
        }
        
        return page
    }
    
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid filename characters
        let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return filename.components(separatedBy: invalidChars).joined(separator: "_")
    }
}

// MARK: - Error Types
enum PDFExportError: LocalizedError {
    case chapterNotDownloaded
    case noImagesFound
    case failedToCreatePDF
    case failedToSavePDF
    case alreadyExporting
    
    var errorDescription: String? {
        switch self {
        case .chapterNotDownloaded:
            return "Chapter is not downloaded"
        case .noImagesFound:
            return "No images found in chapter"
        case .failedToCreatePDF:
            return "Failed to create PDF document"
        case .failedToSavePDF:
            return "Failed to save PDF file"
        case .alreadyExporting:
            return "Chapter is already being exported"
        }
    }
}
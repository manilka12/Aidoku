//
//  ChapterTableCell.swift
//  Aidoku
//
//  Created by Skitty on 8/17/23.
//

import AidokuRunner
import SwiftUI

struct ChapterTableCell: View {
    let source: AidokuRunner.Source?
    let sourceKey: String
    let chapter: AidokuRunner.Chapter
    let read: Bool
    let page: Int?
    let downloaded: Bool
    var downloadProgress: Float?
    
    @State private var upscalingStatus: ChapterUpscalingStatus = .notStarted

    var locked: Bool {
        chapter.locked && !downloaded
    }

    var body: some View {
        HStack {
            if let thumbnail = chapter.thumbnail {
                MangaCoverView(
                    source: source,
                    coverImage: thumbnail,
                    width: 40,
                    height: 40
                )
            }

            VStack(alignment: .leading, spacing: 8 / 3) {
                Text(chapter.formattedTitle())
                    .foregroundStyle(locked || read ? .secondary : .primary)
                    .font(.system(size: 16))
                    .lineLimit(1)
                if let subtitle = chapter.formattedSubtitle(page: page, sourceKey: sourceKey) {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            
            // Upscaling status icon (only for downloaded chapters)
            if downloaded {
                upscalingStatusIcon
            }
            
            if downloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            } else if let downloadProgress {
                DownloadProgressView(progress: CGFloat(downloadProgress))
                    .frame(width: 13, height: 13)
            } else if locked {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 22 / 3)
        .frame(alignment: .leading)
        .contentShape(Rectangle())
        .task {
            if downloaded {
                await loadUpscalingStatus()
            }
        }
    }
    
    @ViewBuilder
    private var upscalingStatusIcon: some View {
        switch upscalingStatus {
        case .notStarted:
            Image(systemName: "wand.and.stars")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                
        case .partiallyUpscaled(let progress):
            ZStack {
                Image(systemName: "wand.and.stars.inverse")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                
                // Optional: Small progress indicator
                if progress < 1.0 {
                    Text("\(Int(progress * 100))")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 0, y: 1)
                }
            }
            
        case .fullyUpscaled:
            Image(systemName: "wand.and.stars.inverse")
                .imageScale(.small)
                .foregroundStyle(.green)
        }
    }
    
    private func loadUpscalingStatus() async {
        // Get chapter directory path
        let cache = await MainActor.run { DownloadCache() }
        let chapterObj = Chapter(
            sourceId: chapter.sourceId,
            id: chapter.id,
            mangaId: chapter.mangaId,
            title: chapter.title,
            sourceOrder: chapter.sourceOrder
        )
        let chapterDirectory = await cache.directory(for: chapterObj)
        
        // Get upscaling status
        let status = DownloadUpscaleManager.getChapterUpscalingStatus(for: chapterDirectory)
        
        await MainActor.run {
            upscalingStatus = status
        }
    }
}

private struct DownloadProgressView: UIViewRepresentable {
    var progress: CGFloat

    func makeUIView(context: Context) -> CircularProgressView {
        let progressView = CircularProgressView(frame: CGRect(x: 0, y: 0, width: 13, height: 13))
        progressView.radius = 13 / 2
        progressView.trackColor = .quaternaryLabel
        progressView.progressColor = progressView.tintColor
        return progressView
    }

    func updateUIView(_ uiView: CircularProgressView, context: Context) {
        uiView.progress = progress
    }
}

//
//  ReaderReaderDelegate.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/16/22.
//

import UIKit

// swiftlint:disable:next class_delegate_protocol
protocol ReaderReaderDelegate: UIViewController {

    var readingMode: ReadingMode { get set }
    var delegate: ReaderHoldingDelegate? { get set }

    func sliderMoved(value: CGFloat)
    func sliderStopped(value: CGFloat)
    func setChapter(_ chapter: Chapter, startPage: Int)
    
    /// Preload the specified page for upscaling
    /// - Parameter page: The page number to preload
    @discardableResult
    func preloadUpscaledPage(_ page: Int) async -> Bool
}

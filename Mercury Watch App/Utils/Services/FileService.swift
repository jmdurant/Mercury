//
//  PhotoManager.swift
//  Mercury Watch App
//
//  Created by Alessandro Alberti on 14/05/24.
//

import SwiftUI
import TDLibKit
import Gzip


class FileService {
    
    static let logger = LoggerService(FileService.self)
    
    static func getImage(for photo: File) async -> UIImage? {
        
        guard let imagePath = await FileService.getPath(for: photo) else {
            logger.log("imagePath is nil")
            return nil
        }
        
        guard let uiImage = UIImage(contentsOfFile: imagePath) else {
            logger.log("Unable to convert file to image")
            return nil
        }
        
        return uiImage
    }
    
    static func getFilePath(for file: File) async -> URL? {
        
        guard let path = await FileService.getPath(for: file) else {
            logger.log("path is nil")
            return nil
        }
        
        return URL(fileURLWithPath: path)
    }
    
    static func getPath(for file: File) async -> String? {

        var filePath = file.local.path

        if filePath.isEmpty {
            do {
                let fileID = file.id
                guard let file = try await TDLibManager.shared.client?.downloadFile(
                    fileId: fileID,
                    limit: 0,
                    offset: 0,
                    priority: 4,
                    synchronous: true
                ) else {
                    logger.log("Unable to retrive file", level: .error)
                    return nil
                }

                filePath = file.local.path

            } catch {
                logger.log(error, level: .error)
            }
        }

        // Validate path is within app sandbox
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        let tmpDir = FileManager.default.temporaryDirectory.path
        guard filePath.hasPrefix(cachesDir) || filePath.hasPrefix(tmpDir) else {
            logger.log("File path outside app sandbox: \(filePath)", level: .error)
            return nil
        }

        return filePath
    }
    
    static func getLottieJson(for tgsPath: URL) -> Data? {
        let zipPath = tgsPath.deletingPathExtension().appendingPathExtension("zip")

        do {
            // Change file extension
            if !FileManager.default.fileExists(atPath: zipPath.path) {
                try FileManager.default.copyItem(at: tgsPath, to: zipPath)
            }
            let sourceData = try Data(contentsOf: zipPath)
            let lottieJSONData = try sourceData.gunzipped()

            // Clean up temporary zip copy
            try? FileManager.default.removeItem(at: zipPath)

            return lottieJSONData
        } catch {
            try? FileManager.default.removeItem(at: zipPath)
            return nil
        }
    }
}

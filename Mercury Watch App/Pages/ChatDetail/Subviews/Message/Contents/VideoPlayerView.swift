//
//  VideoPlayerView.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI
import AVKit

struct VideoPlayerView: View {

    let model: VideoModel

    @State private var player: AVPlayer?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 160)
                    .onAppear {
                        if model.autoplay {
                            player.play()
                        }
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else if isLoading {
                Group {
                    if let thumbnail = model.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(height: 160)
                .overlay {
                    ProgressView()
                }
            }

            if !model.autoplay && player != nil {
                // Show play button overlay for videos (not GIFs)
                // AVPlayer controls handle this, but we ensure visibility
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            if let url = await model.getVideoURL() {
                await MainActor.run {
                    let avPlayer = AVPlayer(url: url)
                    if model.autoplay {
                        avPlayer.actionAtItemEnd = .none
                        // Loop for GIFs
                        NotificationCenter.default.addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: avPlayer.currentItem,
                            queue: .main
                        ) { _ in
                            avPlayer.seek(to: .zero)
                            avPlayer.play()
                        }
                    }
                    self.player = avPlayer
                    self.isLoading = false
                }
            }
        }
    }
}

struct VideoModel {
    var thumbnail: UIImage?
    var autoplay: Bool  // true for GIFs/animations, false for videos
    var caption: String?
    let getVideoURL: () async -> URL?
}

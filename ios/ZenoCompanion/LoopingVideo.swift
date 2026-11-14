import AVFoundation
import SwiftUI

/// Plays a bundled video on a seamless, silent loop.
struct LoopingVideo: UIViewRepresentable {
    let name: String
    var ext = "mov"
    var playing: Bool

    func makeUIView(context: Context) -> PlayerView {
        PlayerView(url: Bundle.main.url(forResource: name, withExtension: ext)!)
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        playing ? view.player.play() : view.player.pause()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            backgroundColor = .clear   // the clip has an alpha channel: the weather shows through
            // Mixes with nothing and never grabs audio: the clip is silent anyway.
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let playerLayer = layer as! AVPlayerLayer
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.clear.cgColor
            playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}

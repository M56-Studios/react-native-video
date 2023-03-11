import AVFoundation
import AVKit
import Foundation
import React
import Promises

class RCTVideo: UIView, RCTVideoPlayerViewControllerDelegate, RCTPlayerObserverHandler {
    private var _player:AVPlayer?
    private var _playerLooper: NSKeyValueObservation?
    private var _playerItem:AVPlayerItem?
    private var _source:VideoSource?
    private var _playerBufferEmpty:Bool = true
    private var _playerLayer:AVPlayerLayer?

    private var _playerViewController:RCTVideoPlayerViewController?
    private var _videoURL:NSURL?

    /* DRM */
    private var _drm:DRMParams?

    private var _localSourceEncryptionKeyScheme:String?

    /* Required to publish events */
    private var _eventDispatcher:RCTEventDispatcherProtocol?
    private var _videoLoadStarted:Bool = false

    private var _pendingSeek:Bool = false
    private var _pendingSeekTime:Float = 0.0
    private var _lastSeekTime:Float = 0.0

    /* For sending videoProgress events */
    private var _controls:Bool = false

    /* Keep track of any modifiers, need to be applied after each play */
    private var _volume:Float = 1.0
    private var _rate:Float = 1.0
    private var _maxBitRate:Float?

    private var _automaticallyWaitsToMinimizeStalling:Bool = true
    private var _muted:Bool = false
    private var _paused:Bool = false
    private var _repeat:Bool = false
    private var _allowsExternalPlayback:Bool = true
    private var _textTracks:[TextTrack]?
    private var _selectedTextTrackCriteria:SelectedTrackCriteria?
    private var _selectedAudioTrackCriteria:SelectedTrackCriteria?
    private var _playbackStalled:Bool = false
    private var _playInBackground:Bool = false
    private var _preventsDisplaySleepDuringVideoPlayback:Bool = true
    private var _preferredForwardBufferDuration:Float = 0.0
    private var _playWhenInactive:Bool = false
    private var _ignoreSilentSwitch:String! = "inherit" // inherit, ignore, obey
    private var _mixWithOthers:String! = "inherit" // inherit, mix, duck
    private var _resizeMode:String! = "AVLayerVideoGravityResizeAspectFill"
    private var _fullscreen:Bool = false
    private var _fullscreenAutorotate:Bool = true
    private var _fullscreenOrientation:String! = "all"
    private var _fullscreenPlayerPresented:Bool = false
    private var _filterName:String!
    private var _filterEnabled:Bool = false
    private var _presentingViewController:UIViewController?

    private var _resouceLoaderDelegate: RCTResourceLoaderDelegate?
    private var _playerObserver: RCTPlayerObserver = RCTPlayerObserver()

#if canImport(RCTVideoCache)
    private let _videoCache:RCTVideoCachingHandler = RCTVideoCachingHandler()
#endif

#if TARGET_OS_IOS
    private let _pip:RCTPictureInPicture = RCTPictureInPicture(self.onPictureInPictureStatusChanged, self.onRestoreUserInterfaceForPictureInPictureStop)
#endif

    // Events
    @objc var onVideoLoadStart: RCTDirectEventBlock?
    @objc var onVideoLoad: RCTDirectEventBlock?
    @objc var onVideoBuffer: RCTDirectEventBlock?
    @objc var onVideoError: RCTDirectEventBlock?
    @objc var onVideoProgress: RCTDirectEventBlock?
    @objc var onBandwidthUpdate: RCTDirectEventBlock?
    @objc var onVideoSeek: RCTDirectEventBlock?
    @objc var onVideoEnd: RCTDirectEventBlock?
    @objc var onTimedMetadata: RCTDirectEventBlock?
    @objc var onVideoAudioBecomingNoisy: RCTDirectEventBlock?
    @objc var onVideoFullscreenPlayerWillPresent: RCTDirectEventBlock?
    @objc var onVideoFullscreenPlayerDidPresent: RCTDirectEventBlock?
    @objc var onVideoFullscreenPlayerWillDismiss: RCTDirectEventBlock?
    @objc var onVideoFullscreenPlayerDidDismiss: RCTDirectEventBlock?
    @objc var onReadyForDisplay: RCTDirectEventBlock?
    @objc var onPlaybackStalled: RCTDirectEventBlock?
    @objc var onPlaybackResume: RCTDirectEventBlock?
    @objc var onPlaybackRateChange: RCTDirectEventBlock?
    @objc var onVideoExternalPlaybackChange: RCTDirectEventBlock?
    @objc var onPictureInPictureStatusChanged: RCTDirectEventBlock?
    @objc var onRestoreUserInterfaceForPictureInPictureStop: RCTDirectEventBlock?
    @objc var onGetLicense: RCTDirectEventBlock?

    init(eventDispatcher:RCTEventDispatcherProtocol!) {
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        _eventDispatcher = eventDispatcher

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(notification:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground(notification:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground(notification:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(notification:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        _playerObserver._handlers = self
#if canImport(RCTVideoCache)
        _videoCache.playerItemPrepareText = playerItemPrepareText
#endif
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        self.removePlayerLayer()
        _playerObserver.clearPlayer()
    }

    // MARK: - App lifecycle handlers

    @objc func applicationWillResignActive(notification:NSNotification!) {
        print("RCTVideo applicationWillResignActive")
        if _playInBackground || _playWhenInactive || _paused {return}

        _player?.pause()
        _player?.rate = 0.0
    }

    @objc func applicationDidEnterBackground(notification:NSNotification!) {
        print("RCTVideo applicationDidEnterBackground")
        if _playInBackground {
            // Needed to play sound in background. See https://developer.apple.com/library/ios/qa/qa1668/_index.html
            _playerLayer?.player = nil
            _playerViewController?.player = nil
        }
    }

    @objc func applicationWillEnterForeground(notification:NSNotification!) {
        print("RCTVideo applicationWillEnterForeground")
        self.applyModifiers()
        if _playInBackground {
            _playerLayer?.player = _player
            _playerViewController?.player = _player
        }
    }

    // MARK: - Audio events

    @objc func audioRouteChanged(notification:NSNotification!) {
        print("RCTVideo audioRouteChanged")
        if let userInfo = notification.userInfo {
            let reason:AVAudioSession.RouteChangeReason! = userInfo[AVAudioSessionRouteChangeReasonKey] as? AVAudioSession.RouteChangeReason
            //            let previousRoute:NSNumber! = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? NSNumber
            if reason == .oldDeviceUnavailable, let onVideoAudioBecomingNoisy = onVideoAudioBecomingNoisy {
                onVideoAudioBecomingNoisy(["target": reactTag as Any])
            }
        }
    }

    // MARK: - Progress

    func sendProgressUpdate() {
        // print("RCTVideo sendProgressUpdate")
        if let video = _player?.currentItem,
           video == nil || video.status != AVPlayerItem.Status.readyToPlay {
            return
        }

        let playerDuration:CMTime = RCTVideoUtils.playerItemDuration(_player)
        if CMTIME_IS_INVALID(playerDuration) {
            return
        }

        let currentTime = _player?.currentTime()
        let currentPlaybackTime = _player?.currentItem?.currentDate()
        let duration = CMTimeGetSeconds(playerDuration)
        let currentTimeSecs = CMTimeGetSeconds(currentTime ?? .zero)

        NotificationCenter.default.post(name: NSNotification.Name("RCTVideo_progress"), object: nil, userInfo: [
            "progress": NSNumber(value: currentTimeSecs / duration)
        ])

        if currentTimeSecs >= 0 {
            onVideoProgress?([
                "currentTime": NSNumber(value: Float(currentTimeSecs)),
                "playableDuration": RCTVideoUtils.calculatePlayableDuration(_player),
                "atValue": NSNumber(value: currentTime?.value ?? .zero),
                "currentPlaybackTime": NSNumber(value: NSNumber(value: floor(currentPlaybackTime?.timeIntervalSince1970 ?? 0 * 1000)).int64Value),
                "target": reactTag,
                "seekableDuration": RCTVideoUtils.calculateSeekableDuration(_player)
            ])
        }
    }

    // MARK: - Player and source
    @objc
    func setUpPlayer(_ playerItem:AVPlayerItem!) {
        print("RCTVideo setUpPlayer")
        _playerObserver.player = nil
        _playerObserver.playerItem = nil

        if #available(iOS 10.0, *) {
            self._playerItem = playerItem

            self._player = self._player ?? AVQueuePlayer()

            self.setUpPlayerItemIos10()

            self._playerObserver.player = self._player
        } else {
            self._playerItem = playerItem

            self._player = self._player ?? AVPlayer()
            self._player?.actionAtItemEnd = .none
            DispatchQueue.global(qos: .default).async {
                self._player?.replaceCurrentItem(with: playerItem)
            }

            self._playerObserver.playerItem = self._playerItem
            self._playerObserver.player = self._player
        }
    }

    func includePlayerItems(replicas: Int) {
        print("RCTVideo includePlayerItems")

        RCTVideoUtils.delay().then { [weak self] in
            guard
                let self = self,
                let playerItem = self._playerItem,
                let player = (self._player as? AVQueuePlayer)
            else { return }

            let missingReplicas = replicas - player.items().count

            if (missingReplicas < 1) {
                return
            }

            print("RCTVideo includePlayerItems adding \(missingReplicas) playerItems")

            for _ in 1...missingReplicas {
                let item = playerItem.copy()

                player.insert(
                    item as! AVPlayerItem,
                    after: player.items().last
                )
            }
        }
    }

    func setUpPlayerItemIos10() {
        print("RCTVideo setUpPlayerItemIos10")
        if #available(iOS 10.0, *) {
            guard
                let playerItem = _playerItem,
                let player = (_player as? AVQueuePlayer)
            else { return }

            player.removeAllItems()
            player.actionAtItemEnd = self._repeat ? .advance : .none

            if !self._repeat {
                DispatchQueue.global(qos: .default).async {
                    player.replaceCurrentItem(with: playerItem)
                }

                _playerObserver.playerItem = playerItem

                return
            }

            _playerLooper?.invalidate()
            _playerLooper = nil

            let replicas = 5

            self._playerLooper = player.observe(\.currentItem) { [weak self] player, _ in
                guard let self = self else { return }

                print("RCTVideo _playerLooper")

                self._playerObserver.playerItem = player.currentItem

                if player.items().count <= replicas {
                    self.includePlayerItems(replicas: replicas)
                }
            }

            self.includePlayerItems(replicas: replicas)
        }
    }

    @objc
    func setSrc(_ source:NSDictionary!) {
        print("RCTVideo setSrc")
        _source = VideoSource(source)
        removePlayerLayer()
        _playerObserver.player = nil
        _playerObserver.playerItem = nil

        // perform on next run loop, otherwise other passed react-props may not be set
        RCTVideoUtils.delay()
            .then{ [weak self] in
                guard let self = self else {throw NSError(domain: "", code: 0, userInfo: nil)}
                guard let source = self._source,
                let assetResult = RCTVideoUtils.prepareAsset(source: source),
                let asset = assetResult.asset,
                let assetOptions = assetResult.assetOptions else {
                      DebugLog("Could not find video URL in source '\(self._source)'")
                      throw NSError(domain: "", code: 0, userInfo: nil)
                  }

#if canImport(RCTVideoCache)
                if self._videoCache.shouldCache(source:source, textTracks:self._textTracks) {
                    return self._videoCache.playerItemForSourceUsingCache(uri: source.uri, assetOptions:assetOptions)
                }
#endif

                if self._drm != nil || self._localSourceEncryptionKeyScheme != nil {
                    self._resouceLoaderDelegate = RCTResourceLoaderDelegate(
                        asset: asset,
                        drm: self._drm,
                        localSourceEncryptionKeyScheme: self._localSourceEncryptionKeyScheme,
                        onVideoError: self.onVideoError,
                        onGetLicense: self.onGetLicense,
                        reactTag: self.reactTag
                    )
                }
                return Promise{self.playerItemPrepareText(asset: asset, assetOptions:assetOptions)}
            }.then{[weak self] (playerItem:AVPlayerItem!) in
                guard let self = self else {throw  NSError(domain: "", code: 0, userInfo: nil)}

                self.setPreferredForwardBufferDuration(self._preferredForwardBufferDuration)
                self.setFilter(self._filterName)
                if let maxBitRate = self._maxBitRate {
                    self._playerItem?.preferredPeakBitRate = Double(maxBitRate)
                }

                self.setUpPlayer(playerItem)
                self.applyModifiers()

                if #available(iOS 10.0, *) {
                    self.setAutomaticallyWaitsToMinimizeStalling(self._automaticallyWaitsToMinimizeStalling)
                }

                //Perform on next run loop, otherwise onVideoLoadStart is nil
                self.onVideoLoadStart?([
                    "src": [
                        "uri": self._source?.uri ?? NSNull(),
                        "type": self._source?.type ?? NSNull(),
                        "isNetwork": NSNumber(value: self._source?.isNetwork ?? false)
                    ],
                    "drm": self._drm?.json ?? NSNull(),
                    "target": self.reactTag
                ])
            }.catch{_ in }
        _videoLoadStarted = true
    }

    @objc
    func setDrm(_ drm:NSDictionary) {
        print("RCTVideo setDrm")
        _drm = DRMParams(drm)
    }

    @objc
    func setLocalSourceEncryptionKeyScheme(_ keyScheme:String) {
        print("RCTVideo setLocalSourceEncryptionKeyScheme")
        _localSourceEncryptionKeyScheme = keyScheme
    }

    func playerItemPrepareText(asset:AVAsset!, assetOptions:NSDictionary?) -> AVPlayerItem {
        print("RCTVideo playerItemPrepareText")
        if (_textTracks == nil) || _textTracks?.count==0 {
            return AVPlayerItem(asset: asset)
        }

        // AVPlayer can't airplay AVMutableCompositions
        _allowsExternalPlayback = false
        let mixComposition = RCTVideoUtils.generateMixComposition(asset)
        let validTextTracks = RCTVideoUtils.getValidTextTracks(
            asset:asset,
            assetOptions:assetOptions,
            mixComposition:mixComposition,
            textTracks:_textTracks)
        if validTextTracks.count != _textTracks?.count {
            setTextTracks(validTextTracks)
        }

        return AVPlayerItem(asset: mixComposition)
    }

    // MARK: - Prop setters

    @objc
    func setResizeMode(_ mode: String?) {
        print("RCTVideo setResizeMode")
        if _controls {
            _playerViewController?.videoGravity = AVLayerVideoGravity(rawValue: mode ?? "")
        } else {
            _playerLayer?.videoGravity = AVLayerVideoGravity(rawValue: mode ?? "")
        }
        _resizeMode = mode
    }

    @objc
    func setPlayInBackground(_ playInBackground:Bool) {
        print("RCTVideo setPlayInBackground")
        _playInBackground = playInBackground
    }

    @objc
    func setPreventsDisplaySleepDuringVideoPlayback(_ preventsDisplaySleepDuringVideoPlayback:Bool) {
        print("RCTVideo setPreventsDisplaySleepDuringVideoPlayback")
        _preventsDisplaySleepDuringVideoPlayback = preventsDisplaySleepDuringVideoPlayback
        self.applyModifiers()
    }

    @objc
    func setAllowsExternalPlayback(_ allowsExternalPlayback:Bool) {
        print("RCTVideo setAllowsExternalPlayback")
        _allowsExternalPlayback = allowsExternalPlayback
        _player?.allowsExternalPlayback = _allowsExternalPlayback
    }

    @objc
    func setPlayWhenInactive(_ playWhenInactive:Bool) {
        print("RCTVideo setPlayWhenInactive")
        _playWhenInactive = playWhenInactive
    }

    @objc
    func setPictureInPicture(_ pictureInPicture:Bool) {
        print("RCTVideo setPictureInPicture")
#if TARGET_OS_IOS
        _pip.setPictureInPicture(pictureInPicture)
#endif
    }

    @objc
    func setRestoreUserInterfaceForPIPStopCompletionHandler(_ restore:Bool) {
        print("RCTVideo setRestoreUserInterfaceForPIPStopCompletionHandler")
#if TARGET_OS_IOS
        _pip.setRestoreUserInterfaceForPIPStopCompletionHandler(restore)
#endif
    }

    @objc
    func setIgnoreSilentSwitch(_ ignoreSilentSwitch:String?) {
        print("RCTVideo setIgnoreSilentSwitch")
        _ignoreSilentSwitch = ignoreSilentSwitch
        RCTPlayerOperations.configureAudio(ignoreSilentSwitch:_ignoreSilentSwitch, mixWithOthers:_mixWithOthers)
        applyModifiers()
    }

    @objc
    func setMixWithOthers(_ mixWithOthers:String?) {
        print("RCTVideo setMixWithOthers")
        _mixWithOthers = mixWithOthers
        applyModifiers()
    }

    @objc
    func setPaused(_ paused:Bool) {
        print("RCTVideo setPaused")
        if paused {
            _player?.pause()
            _player?.rate = 0.0
        } else {
            RCTPlayerOperations.configureAudio(ignoreSilentSwitch:_ignoreSilentSwitch, mixWithOthers:_mixWithOthers)

            if #available(iOS 10.0, *), !_automaticallyWaitsToMinimizeStalling {
                _player?.playImmediately(atRate: _rate)
            } else {
                _player?.play()
                _player?.rate = _rate
            }
            _player?.rate = _rate
        }

        _paused = paused
    }

    @objc
    func setCurrentTime(_ currentTime:Float) {
        print("RCTVideo setCurrentTime")
        let info:NSDictionary = [
            "time": NSNumber(value: currentTime),
            "tolerance": NSNumber(value: 100)
        ]
        setSeek(info)
    }

    @objc
    func setSeek(_ info:NSDictionary!) {
        print("RCTVideo setSeek")
        let seekTime:NSNumber! = info["time"] as! NSNumber
        let seekTolerance:NSNumber! = info["tolerance"] as! NSNumber
        let item:AVPlayerItem? = _player?.currentItem
        guard item != nil, let player = _player, let item = item, item.status == AVPlayerItem.Status.readyToPlay else {
            _pendingSeek = true
            _pendingSeekTime = seekTime.floatValue
            return
        }
        let wasPaused = _paused

        RCTPlayerOperations.seek(
            player:player,
            playerItem:item,
            paused:wasPaused,
            seekTime:seekTime.floatValue,
            seekTolerance:seekTolerance.floatValue)
            .then{ [weak self] (finished:Bool) in
                guard let self = self else { return }

                self._playerObserver.addTimeObserverIfNotSet()
                if !wasPaused {
                    self.setPaused(false)
                }
                self.onVideoSeek?(["currentTime": NSNumber(value: Float(CMTimeGetSeconds(item.currentTime()))),
                                   "seekTime": seekTime,
                                   "target": self.reactTag])
            }.catch{_ in }

        _pendingSeek = false
    }

    @objc
    func setRate(_ rate:Float) {
        print("RCTVideo setRate")
        _rate = rate
        applyModifiers()
    }

    @objc
    func setMuted(_ muted:Bool) {
        print("RCTVideo setMuted")
        _muted = muted
        applyModifiers()
    }

    @objc
    func setVolume(_ volume:Float) {
        print("RCTVideo setVolume")
        _volume = volume
        applyModifiers()
    }

    @objc
    func setMaxBitRate(_ maxBitRate:Float) {
        print("RCTVideo setMaxBitRate")
        _maxBitRate = maxBitRate
        _playerItem?.preferredPeakBitRate = Double(maxBitRate)
    }

    @objc
    func setPreferredForwardBufferDuration(_ preferredForwardBufferDuration:Float) {
        print("RCTVideo setPreferredForwardBufferDuration")
        _preferredForwardBufferDuration = preferredForwardBufferDuration
        if #available(iOS 10.0, *) {
            _playerItem?.preferredForwardBufferDuration = TimeInterval(preferredForwardBufferDuration)
        } else {
            // Fallback on earlier versions
        }
    }

    @objc
    func setAutomaticallyWaitsToMinimizeStalling(_ waits:Bool) {
        print("RCTVideo setAutomaticallyWaitsToMinimizeStalling")
        _automaticallyWaitsToMinimizeStalling = waits
        if #available(iOS 10.0, *) {
            _player?.automaticallyWaitsToMinimizeStalling = waits
        } else {
            // Fallback on earlier versions
        }
    }


    func applyModifiers() {
        print("RCTVideo applyModifiers")
        if _muted {
            if !_controls {
                _player?.volume = 0
            }
            _player?.isMuted = true
        } else {
            _player?.volume = _volume
            _player?.isMuted = false
        }

        if #available(iOS 12.0, *) {
            _player?.preventsDisplaySleepDuringVideoPlayback = _preventsDisplaySleepDuringVideoPlayback
        } else {
            // Fallback on earlier versions
        }

        if let _maxBitRate = _maxBitRate {
            setMaxBitRate(_maxBitRate)
        }

        setSelectedAudioTrack(_selectedAudioTrackCriteria)
        setSelectedTextTrack(_selectedTextTrackCriteria)
        setResizeMode(_resizeMode)
        setRepeat(_repeat)
        setControls(_controls)
        setPaused(_paused)
        setAllowsExternalPlayback(_allowsExternalPlayback)
    }

    @objc
    func setRepeat(_ `repeat`: Bool) {
        print("RCTVideo setRepeat")
        let newRepeat = `repeat`

        if newRepeat == _repeat {
            return
        }

        _repeat = newRepeat

        self.setUpPlayerItemIos10()
    }

    @objc
    func setSelectedAudioTrack(_ selectedAudioTrack:NSDictionary?) {
        print("RCTVideo setSelectedAudioTrack")
        setSelectedAudioTrack(SelectedTrackCriteria(selectedAudioTrack))
    }

    func setSelectedAudioTrack(_ selectedAudioTrack:SelectedTrackCriteria?) {
        print("RCTVideo setSelectedAudioTrack")
        _selectedAudioTrackCriteria = selectedAudioTrack
        RCTPlayerOperations.setMediaSelectionTrackForCharacteristic(player:_player, characteristic: AVMediaCharacteristic.audible,
                                                                    criteria:_selectedAudioTrackCriteria)
    }

    @objc
    func setSelectedTextTrack(_ selectedTextTrack:NSDictionary?) {
        print("RCTVideo setSelectedTextTrack")
        setSelectedTextTrack(SelectedTrackCriteria(selectedTextTrack))
    }

    func setSelectedTextTrack(_ selectedTextTrack:SelectedTrackCriteria?) {
        print("RCTVideo setSelectedTextTrack")
        _selectedTextTrackCriteria = selectedTextTrack
        if (_textTracks != nil) { // sideloaded text tracks
            RCTPlayerOperations.setSideloadedText(player:_player, textTracks:_textTracks, criteria:_selectedTextTrackCriteria)
        } else { // text tracks included in the HLS playlist
            RCTPlayerOperations.setMediaSelectionTrackForCharacteristic(player:_player, characteristic: AVMediaCharacteristic.legible,
                                                                        criteria:_selectedTextTrackCriteria)
        }
    }

    @objc
    func setTextTracks(_ textTracks:[NSDictionary]?) {
        print("RCTVideo setTextTracks")
        setTextTracks(textTracks?.map { TextTrack($0) })
    }

    func setTextTracks(_ textTracks:[TextTrack]?) {
        print("RCTVideo setTextTracks")
        _textTracks = textTracks

        // in case textTracks was set after selectedTextTrack
        if (_selectedTextTrackCriteria != nil) {setSelectedTextTrack(_selectedTextTrackCriteria)}
    }

    @objc
    func setFullscreen(_ fullscreen:Bool) {
        print("RCTVideo setFullscreen")
        if fullscreen && !_fullscreenPlayerPresented && _player != nil {
            // Ensure player view controller is not null
            if _playerViewController == nil {
                self.usePlayerViewController()
            }

            // Set presentation style to fullscreen
            _playerViewController?.modalPresentationStyle = .fullScreen

            // Find the nearest view controller
            var viewController:UIViewController! = self.firstAvailableUIViewController()
            if (viewController == nil) {
                let keyWindow:UIWindow! = UIApplication.shared.keyWindow
                viewController = keyWindow.rootViewController
                if viewController.children.count > 0
                {
                    viewController = viewController.children.last
                }
            }
            if viewController != nil {
                _presentingViewController = viewController

                self.onVideoFullscreenPlayerWillPresent?(["target": reactTag as Any])

                viewController.present(viewController, animated:true, completion:{
                    self._playerViewController?.showsPlaybackControls = true
                    self._fullscreenPlayerPresented = fullscreen
                    self._playerViewController?.autorotate = self._fullscreenAutorotate

                    self.onVideoFullscreenPlayerDidPresent?(["target": self.reactTag])

                })
            }
        } else if !fullscreen && _fullscreenPlayerPresented, let _playerViewController = _playerViewController {
            self.videoPlayerViewControllerWillDismiss(playerViewController: _playerViewController)
            _presentingViewController?.dismiss(animated: true, completion:{
                self.videoPlayerViewControllerDidDismiss(playerViewController: _playerViewController)
            })
        }
    }

    @objc
    func setFullscreenAutorotate(_ autorotate:Bool) {
        print("RCTVideo setFullscreenAutorotate")
        _fullscreenAutorotate = autorotate
        if _fullscreenPlayerPresented {
            _playerViewController?.autorotate = autorotate
        }
    }

    @objc
    func setFullscreenOrientation(_ orientation:String?) {
        print("RCTVideo setFullscreenOrientation")
        _fullscreenOrientation = orientation
        if _fullscreenPlayerPresented {
            _playerViewController?.preferredOrientation = orientation
        }
    }

    func usePlayerViewController() {
        print("RCTVideo usePlayerViewController")
        guard let _player = _player, let _playerItem = _playerItem else { return }

        if _playerViewController == nil {
            _playerViewController = createPlayerViewController(player:_player, withPlayerItem:_playerItem)
        }
        // to prevent video from being animated when resizeMode is 'cover'
        // resize mode must be set before subview is added
        setResizeMode(_resizeMode)

        guard let _playerViewController = _playerViewController else { return }

        if _controls {
            let viewController:UIViewController! = self.reactViewController()
            viewController.addChild(_playerViewController)
            self.addSubview(_playerViewController.view)
        }

        _playerObserver.playerViewController = _playerViewController
    }

    func createPlayerViewController(player:AVPlayer, withPlayerItem playerItem:AVPlayerItem) -> RCTVideoPlayerViewController {
        print("RCTVideo createPlayerViewController")
        let viewController = RCTVideoPlayerViewController()
        viewController.showsPlaybackControls = true
        viewController.rctDelegate = self
        viewController.preferredOrientation = _fullscreenOrientation

        viewController.view.frame = self.bounds
        viewController.player = player
        return viewController
    }

    func usePlayerLayer() {
        print("RCTVideo usePlayerLayer")
        if let _player = _player {
            _playerLayer = AVPlayerLayer(player: _player)
            _playerLayer?.frame = self.bounds
            _playerLayer?.needsDisplayOnBoundsChange = true

            // to prevent video from being animated when resizeMode is 'cover'
            // resize mode must be set before layer is added
            setResizeMode(_resizeMode)
            _playerObserver.playerLayer = _playerLayer

            if let _playerLayer = _playerLayer {
                self.layer.addSublayer(_playerLayer)
            }
            self.layer.needsDisplayOnBoundsChange = true
#if TARGET_OS_IOS
            _pip.setupPipController(_playerLayer)
#endif
        }
    }

    @objc
    func setControls(_ controls:Bool) {
        print("RCTVideo setControls")
        if _controls != controls || ((_playerLayer == nil) && (_playerViewController == nil))
        {
            _controls = controls
            if _controls
            {
                self.removePlayerLayer()
                self.usePlayerViewController()
            }
            else
            {
                _playerViewController?.view.removeFromSuperview()
                _playerViewController = nil
                _playerObserver.playerViewController = nil
                self.usePlayerLayer()
            }
        }
    }

    @objc
    func setProgressUpdateInterval(_ progressUpdateInterval:Float) {
        print("RCTVideo setProgressUpdateInterval")
        _playerObserver.replaceTimeObserverIfSet(Float64(progressUpdateInterval))
    }

    func removePlayerLayer() {
        print("RCTVideo removePlayerLayer")
        _resouceLoaderDelegate = nil
        _playerLayer?.removeFromSuperlayer()
        _playerLayer = nil
        _playerObserver.playerLayer = nil
    }

    // MARK: - RCTVideoPlayerViewControllerDelegate

    func videoPlayerViewControllerWillDismiss(playerViewController:AVPlayerViewController) {
        print("RCTVideo videoPlayerViewControllerWillDismiss")
        if _playerViewController == playerViewController && _fullscreenPlayerPresented, let onVideoFullscreenPlayerWillDismiss = onVideoFullscreenPlayerWillDismiss {
            _playerObserver.removePlayerViewControllerObservers()
            onVideoFullscreenPlayerWillDismiss(["target": reactTag as Any])
        }
    }


    func videoPlayerViewControllerDidDismiss(playerViewController:AVPlayerViewController) {
        print("RCTVideo videoPlayerViewControllerDidDismiss")
        if _playerViewController == playerViewController && _fullscreenPlayerPresented {
            _fullscreenPlayerPresented = false
            _presentingViewController = nil
            _playerViewController = nil
            _playerObserver.playerViewController = nil
            self.applyModifiers()

            onVideoFullscreenPlayerDidDismiss?(["target": reactTag as Any])
        }
    }

    @objc
    func setFilter(_ filterName:String!) {
        print("RCTVideo setFilter")
        _filterName = filterName

        if !_filterEnabled {
            return
        } else if let uri = _source?.uri, uri.contains("m3u8") {
            return // filters don't work for HLS... return
        } else if _playerItem?.asset == nil {
            return
        }

        let filter:CIFilter! = CIFilter(name: filterName)
        if #available(iOS 9.0, *), let _playerItem = _playerItem {
            self._playerItem?.videoComposition = AVVideoComposition(
                asset: _playerItem.asset,
                applyingCIFiltersWithHandler: { (request:AVAsynchronousCIImageFilteringRequest) in
                    if filter == nil {
                        request.finish(with: request.sourceImage, context:nil)
                    } else {
                        let image:CIImage! = request.sourceImage.clampedToExtent()
                        filter.setValue(image, forKey:kCIInputImageKey)
                        let output:CIImage! = filter.outputImage?.cropped(to: request.sourceImage.extent)
                        request.finish(with: output, context:nil)
                    }
                })
        } else {
            // Fallback on earlier versions
        }
    }

    @objc
    func setFilterEnabled(_ filterEnabled:Bool) {
        print("RCTVideo setFilterEnabled")
        _filterEnabled = filterEnabled
    }

    // MARK: - React View Management

    func insertReactSubview(view:UIView!, atIndex:Int) {
        print("RCTVideo insertReactSubview")
        // We are early in the game and somebody wants to set a subview.
        // That can only be in the context of playerViewController.
        if !_controls && (_playerLayer == nil) && (_playerViewController == nil) {
            setControls(true)
        }

        if _controls {
            view.frame = self.bounds
            _playerViewController?.contentOverlayView?.insertSubview(view, at:atIndex)
        } else {
            RCTLogError("video cannot have any subviews")
        }
        return
    }

    func removeReactSubview(subview:UIView!) {
        print("RCTVideo removeReactSubview")
        if _controls {
            subview.removeFromSuperview()
        } else {
            RCTLog("video cannot have any subviews")
        }
        return
    }

    override func layoutSubviews() {
        print("RCTVideo layoutSubviews")
        super.layoutSubviews()
        if _controls, let _playerViewController = _playerViewController {
            _playerViewController.view.frame = bounds

            // also adjust all subviews of contentOverlayView
            for subview in _playerViewController.contentOverlayView?.subviews ?? [] {
                subview.frame = bounds
            }
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            _playerLayer?.frame = bounds
            CATransaction.commit()
        }
    }

    // MARK: - Lifecycle

    override func removeFromSuperview() {
        print("RCTVideo removeFromSuperview")
        _player?.pause()
        _player = nil

        _playerLooper?.invalidate()
        _playerLooper = nil

        _playerObserver.clearPlayer()

        self.removePlayerLayer()

        if let _playerViewController = _playerViewController {
            _playerViewController.view.removeFromSuperview()
            _playerViewController.rctDelegate = nil
            _playerViewController.player = nil
            self._playerViewController = nil
            _playerObserver.playerViewController = nil
        }

        _eventDispatcher = nil
        NotificationCenter.default.removeObserver(self)

        super.removeFromSuperview()
    }

    // MARK: - Export

    @objc
    func save(options:NSDictionary!, resolve: @escaping RCTPromiseResolveBlock, reject:@escaping RCTPromiseRejectBlock) {
        print("RCTVideo save")
        RCTVideoSave.save(
            options:options,
            resolve:resolve,
            reject:reject,
            playerItem:_playerItem
        )
    }

    func setLicenseResult(_ license:String!) {
        print("RCTVideo setLicenseResult")
        _resouceLoaderDelegate?.setLicenseResult(license)
    }

    func setLicenseResultError(_ error:String!) {
        print("RCTVideo setLicenseResultError")
        _resouceLoaderDelegate?.setLicenseResultError(error)
    }

    // MARK: - RCTPlayerObserverHandler

    func handleTimeUpdate(time:CMTime) {
        // print("RCTVideo handleTimeUpdate")
        sendProgressUpdate()
    }

    func handleReadyForDisplay(changeObject: Any, change:NSKeyValueObservedChange<Bool>) {
        print("RCTVideo handleReadyForDisplay")
        onReadyForDisplay?([
            "target": reactTag
        ])
    }

    // When timeMetadata is read the event onTimedMetadata is triggered
    func handleTimeMetadataChange(playerItem:AVPlayerItem, change:NSKeyValueObservedChange<[AVMetadataItem]?>) {
        print("RCTVideo handleTimeMetadataChange")
        guard let newValue = change.newValue, let _items = newValue, _items.count > 0 else {
            return
        }

        var metadata: [[String:String?]?] = []
        for item in _items {
            let value = item.value as? String
            let identifier = item.identifier?.rawValue

            if let value = value {
                metadata.append(["value":value, "identifier":identifier])
            }
        }

        onTimedMetadata?([
            "target": reactTag,
            "metadata": metadata
        ])
    }

    // Handle player item status change.
    func handlePlayerItemStatusChange(playerItem:AVPlayerItem, change:NSKeyValueObservedChange<AVPlayerItem.Status>) {
        print("RCTVideo handlePlayerItemStatusChange")
        guard let _playerItem = _playerItem else {
            return
        }

        if _playerItem.status == .readyToPlay {
            handleReadyToPlay()
        } else if _playerItem.status == .failed {
            handlePlaybackFailed()
        }
    }

    func handleReadyToPlay() {
        print("RCTVideo handleReadyToPlay")
        guard let _playerItem = _playerItem else { return }
        var duration:Float = Float(CMTimeGetSeconds(_playerItem.asset.duration))

        if duration.isNaN {
            duration = 0.0
        }

        var width: Float? = nil
        var height: Float? = nil
        var orientation = "undefined"

        if _playerItem.asset.tracks(withMediaType: AVMediaType.video).count > 0 {
            let videoTrack = _playerItem.asset.tracks(withMediaType: .video)[0]
            width = Float(videoTrack.naturalSize.width)
            height = Float(videoTrack.naturalSize.height)
            let preferredTransform = videoTrack.preferredTransform

            if (videoTrack.naturalSize.width == preferredTransform.tx
                && videoTrack.naturalSize.height == preferredTransform.ty)
                || (preferredTransform.tx == 0 && preferredTransform.ty == 0)
            {
                orientation = "landscape"
            } else {
                orientation = "portrait"
            }
        } else if _playerItem.presentationSize.height != 0.0 {
            width = Float(_playerItem.presentationSize.width)
            height = Float(_playerItem.presentationSize.height)
            orientation = _playerItem.presentationSize.width > _playerItem.presentationSize.height ? "landscape" : "portrait"
        }

        if _pendingSeek {
            setCurrentTime(_pendingSeekTime)
            _pendingSeek = false
        }

        if _videoLoadStarted {
            onVideoLoad?(["duration": NSNumber(value: duration),
                          "currentTime": NSNumber(value: Float(CMTimeGetSeconds(_playerItem.currentTime()))),
                          "canPlayReverse": NSNumber(value: _playerItem.canPlayReverse),
                          "canPlayFastForward": NSNumber(value: _playerItem.canPlayFastForward),
                          "canPlaySlowForward": NSNumber(value: _playerItem.canPlaySlowForward),
                          "canPlaySlowReverse": NSNumber(value: _playerItem.canPlaySlowReverse),
                          "canStepBackward": NSNumber(value: _playerItem.canStepBackward),
                          "canStepForward": NSNumber(value: _playerItem.canStepForward),
                          "naturalSize": [
                            "width": width != nil ? NSNumber(value: width!) : "undefinded",
                            "height": width != nil ? NSNumber(value: height!) : "undefinded",
                            "orientation": orientation
                          ],
                          "audioTracks": RCTVideoUtils.getAudioTrackInfo(_player),
                          "textTracks": _textTracks ?? RCTVideoUtils.getTextTrackInfo(_player),
                          "target": reactTag as Any])
        }
        _videoLoadStarted = false
        _playerObserver.attachPlayerEventListeners()
        applyModifiers()
    }

    func handlePlaybackFailed() {
        print("RCTVideo handlePlaybackFailed")
        guard let _playerItem = _playerItem else { return }
        onVideoError?(
            [
                "error": [
                    "code": NSNumber(value: (_playerItem.error! as NSError).code),
                    "localizedDescription": _playerItem.error?.localizedDescription == nil ? "" : _playerItem.error?.localizedDescription,
                    "localizedFailureReason": ((_playerItem.error! as NSError).localizedFailureReason == nil ? "" : (_playerItem.error! as NSError).localizedFailureReason) ?? "",
                    "localizedRecoverySuggestion": ((_playerItem.error! as NSError).localizedRecoverySuggestion == nil ? "" : (_playerItem.error! as NSError).localizedRecoverySuggestion) ?? "",
                    "domain": (_playerItem.error as! NSError).domain
                ],
                "target": reactTag
            ])
    }

    func handlePlaybackBufferKeyEmpty(playerItem:AVPlayerItem, change:NSKeyValueObservedChange<Bool>) {
        print("RCTVideo handlePlaybackBufferKeyEmpty")
        _playerBufferEmpty = true
        onVideoBuffer?(["isBuffering": true, "target": reactTag as Any])
    }

    // Continue playing (or not if paused) after being paused due to hitting an unbuffered zone.
    func handlePlaybackLikelyToKeepUp(playerItem:AVPlayerItem, change:NSKeyValueObservedChange<Bool>) {
        print("RCTVideo handlePlaybackLikelyToKeepUp")
        if (
            (!(_controls || _fullscreenPlayerPresented) || _playerBufferEmpty) &&
            _playerItem?.isPlaybackLikelyToKeepUp == true
        )
        {
            setPaused(_paused)
        }

        _playerBufferEmpty = false
        onVideoBuffer?(["isBuffering": false, "target": reactTag as Any])
    }

    func handlePlaybackRateChange(player: AVPlayer, change: NSKeyValueObservedChange<Float>) {
        print("RCTVideo handlePlaybackRateChange")
        guard let _player = _player else { return }
        onPlaybackRateChange?(["playbackRate": NSNumber(value: _player.rate),
                               "target": reactTag as Any])
        if _playbackStalled && _player.rate > 0 {
            onPlaybackResume?(["playbackRate": NSNumber(value: _player.rate),
                               "target": reactTag as Any])
            _playbackStalled = false
        }
    }

    func handleExternalPlaybackActiveChange(player: AVPlayer, change: NSKeyValueObservedChange<Bool>) {
        print("RCTVideo handleExternalPlaybackActiveChange")
        guard let _player = _player else { return }
        onVideoExternalPlaybackChange?(["isExternalPlaybackActive": NSNumber(value: _player.isExternalPlaybackActive),
                                        "target": reactTag as Any])
    }

    func handleViewControllerOverlayViewFrameChange(overlayView:UIView, change:NSKeyValueObservedChange<CGRect>) {
        print("RCTVideo handleViewControllerOverlayViewFrameChange")
        let oldRect = change.oldValue
        let newRect = change.newValue
        if !oldRect!.equalTo(newRect!) {
            if newRect!.equalTo(UIScreen.main.bounds) {
                NSLog("in fullscreen")

                self.reactViewController().view.frame = UIScreen.main.bounds
                self.reactViewController().view.setNeedsLayout()
            } else {NSLog("not fullscreen")}
        }
    }

    @objc func handleDidFailToFinishPlaying(notification:NSNotification!) {
        print("RCTVideo handleDidFailToFinishPlaying")
        let error:NSError! = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        onVideoError?(
            [
                "error": [
                    "code": NSNumber(value: (error as NSError).code),
                    "localizedDescription": error.localizedDescription ?? "",
                    "localizedFailureReason": (error as NSError).localizedFailureReason ?? "",
                    "localizedRecoverySuggestion": (error as NSError).localizedRecoverySuggestion ?? "",
                    "domain": (error as NSError).domain
                ],
                "target": reactTag
            ])
    }

    @objc func handlePlaybackStalled(notification:NSNotification!) {
        print("RCTVideo handlePlaybackStalled")
        onPlaybackStalled?(["target": reactTag as Any])
        _playbackStalled = true
    }

    @objc func handlePlayerItemDidReachEnd(notification:NSNotification!) {
        print("RCTVideo handlePlayerItemDidReachEnd")
        onVideoEnd?(["target": reactTag as Any])

        if #available(iOS 10.0, *) {
            // New looper setup is available
            return
        }

        if _repeat {
            let item:AVPlayerItem! = notification.object as? AVPlayerItem
            item.seek(to: CMTime.zero)
            self.applyModifiers()
        }
    }
}

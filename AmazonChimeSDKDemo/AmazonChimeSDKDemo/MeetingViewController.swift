//
//  MeetingViewController.swift
//  AmazonChimeSDKDemo
//
//  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//  SPDX-License-Identifier: Apache-2.0
//

import AmazonChimeSDK
import AVFoundation
import Foundation
import Toast
import UIKit

class MeetingViewController: UIViewController {
    // MARK: Initialize variables

    @IBOutlet var attendeesButton: UIButton!
    @IBOutlet var cameraButton: UIButton!
    @IBOutlet var controlView: UIView!
    @IBOutlet var deviceButton: UIButton!
    @IBOutlet var endButton: UIButton!
    @IBOutlet var mainView: UIView!
    @IBOutlet var meetingNameLabel: UILabel!
    @IBOutlet var moreButton: UIButton!
    @IBOutlet var muteButton: UIButton!
    @IBOutlet var screenButton: UIButton!
    @IBOutlet var screenView: UIView!
    @IBOutlet var screenViewLabel: UILabel!
    @IBOutlet var screenRenderView: DefaultVideoRenderView!
    @IBOutlet var titleView: UIView!
    @IBOutlet var rosterTable: UITableView!
    @IBOutlet var videoCollection: UICollectionView!

    public var meetingSessionConfig: MeetingSessionConfiguration?
    public var meetingId: String?
    public var selfName: String?

    private var currentMeetingSession: MeetingSession?
    private let dispatchGroup = DispatchGroup()
    private var isFullScreen = false
    private let jsonDecoder = JSONDecoder()
    private let logger = ConsoleLogger(name: "MeetingViewController")
    private let maxVideoTileCount = 16
    private var metricsDict = MetricsDictionary()
    private let uuid = UUID().uuidString

    private let rosterModel = RosterModel()
    private let videoTileCellReuseIdentifier = "VideoTileCell"
    private var videoTileStates: [VideoTileState?] = [nil]
    private var videoTileStatesForDisplay: ArraySlice<VideoTileState?> = ArraySlice(repeating: nil, count: 1)
    private var videoTileIdToIndexPath: [Int: IndexPath] = [:]

    // MARK: Override functions

    override func viewDidLoad() {
        guard let meetingSessionConfig = meetingSessionConfig else {
            logger.error(msg: "Unable to get meeting session")
            return
        }

        super.viewDidLoad()
        setupUI()

        DispatchQueue.global(qos: .background).async {
            self.currentMeetingSession = DefaultMeetingSession(
                configuration: meetingSessionConfig, logger: self.logger
            )
            self.setupAudioEnv()
            DispatchQueue.main.async {
                self.startRemoteVideo()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard let layout = videoCollection.collectionViewLayout as? UICollectionViewFlowLayout else {
            return
        }
        if UIDevice.current.orientation.isLandscape {
            layout.scrollDirection = .horizontal
        } else {
            layout.scrollDirection = .vertical
            isFullScreen = false
            controlView.isHidden = false
        }
    }

    private func setupAudioEnv() {
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playAndRecord, options:
                AVAudioSession.CategoryOptions.allowBluetooth)
            setupSubscriptionToAttendeeChangeHandler()
            try currentMeetingSession?.audioVideo.start(callKitEnabled: false)
        } catch PermissionError.audioPermissionError {
            let audioPermission = AVAudioSession.sharedInstance().recordPermission
            if audioPermission == .denied {
                logger.error(msg: "User did not grant audio permission, it should redirect to Settings")
                DispatchQueue.main.async {
                    self.dismiss(animated: true, completion: nil)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    if granted {
                        self.setupAudioEnv()
                    } else {
                        self.logger.error(msg: "User did not grant audio permission")
                        DispatchQueue.main.async {
                            self.dismiss(animated: true, completion: nil)
                        }
                    }
                }
            }
        } catch {
            logger.error(msg: "Error starting the Meeting: \(error.localizedDescription)")
            leaveMeeting()
        }
    }

    private func setupVideoEnv() {
        do {
            try currentMeetingSession?.audioVideo.startLocalVideo()
        } catch PermissionError.videoPermissionError {
            let videoPermission = AVCaptureDevice.authorizationStatus(for: .video)
            if videoPermission == .denied {
                logger.error(msg: "User did not grant video permission, it should redirect to Settings")
                notify(msg: "You did not grant video permission, Please go to Settings and change it")
            } else {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        self.setupVideoEnv()
                    } else {
                        self.logger.error(msg: "User did not grant video permission")
                        self.notify(msg: "You did not grant video permission, Please go to Settings and change it")
                    }
                }
            }
        } catch {
            logger.error(msg: "Error starting the Meeting: \(error.localizedDescription)")
            leaveMeeting()
        }
    }

    func setupSubscriptionToAttendeeChangeHandler() {
        guard let audioVideo = currentMeetingSession?.audioVideo else {
            return
        }
        audioVideo.addVideoTileObserver(observer: self)
        audioVideo.addRealtimeObserver(observer: self)
        audioVideo.addAudioVideoObserver(observer: self)
        audioVideo.addMetricsObserver(observer: self)
        audioVideo.addDeviceChangeObserver(observer: self)
        audioVideo.addActiveSpeakerObserver(policy: DefaultActiveSpeakerPolicy(),
                                            observer: self)
    }

    func removeSubscriptionToAttendeeChangeHandler() {
        guard let audioVideo = currentMeetingSession?.audioVideo else {
            return
        }
        audioVideo.removeVideoTileObserver(observer: self)
        audioVideo.removeRealtimeObserver(observer: self)
        audioVideo.removeAudioVideoObserver(observer: self)
        audioVideo.removeMetricsObserver(observer: self)
        audioVideo.removeDeviceChangeObserver(observer: self)
        audioVideo.removeActiveSpeakerObserver(observer: self)
    }

    private func notify(msg: String) {
        logger.info(msg: msg)
        view.makeToast(msg, duration: 2.0)
    }

    private func getMaxIndexOfVisibleVideoTiles() -> Int {
        // If local video was not enabled, we can show one more remote video
        let maxRemoteVideoTileCount = maxVideoTileCount - (videoTileStates[0] == nil ? 0 : 1)
        return min(maxRemoteVideoTileCount, videoTileStates.count - 1)
    }

    // MARK: UI functions

    private func setupUI() {
        // Labels
        meetingNameLabel.text = meetingId
        meetingNameLabel.accessibilityLabel = "Meeting ID \(meetingId ?? "")"

        // Buttons
        let buttonStack = [muteButton, deviceButton, cameraButton, screenButton, attendeesButton, endButton, moreButton]
        for button in buttonStack {
            let normalButtonImage = button?.image(for: .normal)?.withRenderingMode(.alwaysTemplate)
            let selectedButtonImage = button?.image(for: .selected)?.withRenderingMode(.alwaysTemplate)
            button?.setImage(normalButtonImage, for: .normal)
            button?.setImage(selectedButtonImage, for: .selected)
            button?.imageView?.contentMode = UIView.ContentMode.scaleAspectFit
            button?.tintColor = .systemGray
        }
        endButton.tintColor = .red

        // Views
        let tap = UITapGestureRecognizer(target: self, action: #selector(setFullScreen(_:)))
        mainView.addGestureRecognizer(tap)

        // States
        showVideoOrScreen(isVideo: true)

        // roster table view
        rosterTable.delegate = rosterModel
        rosterTable.dataSource = rosterModel
    }

    private func showVideoOrScreen(isVideo: Bool) {
        attendeesButton.isSelected = false
        moreButton.isSelected = false
        rosterTable.isHidden = true
        screenView.isHidden = isVideo
        videoCollection.isHidden = !isVideo
    }

    private func startRemoteVideo() {
        currentMeetingSession?.audioVideo.stopRemoteVideo()
        for index in 1 ..< videoTileStatesForDisplay.count {
            if let tileState = videoTileStatesForDisplay[index] {
                currentMeetingSession?.audioVideo.resumeRemoteVideoTile(tileId: tileState.tileId)
                if let indexPath = videoTileIdToIndexPath[tileState.tileId],
                    let otherVideoTileCell = videoCollection.cellForItem(at: indexPath) as? VideoTileCell {
                    otherVideoTileCell.onTileButton.isSelected = false
                }
            }
        }
        currentMeetingSession?.audioVideo.startRemoteVideo()
        showVideoOrScreen(isVideo: true)
    }

    private func startScreenShare() {
        // Skip index 0 as it's reserved for self video tile
        for index in 1 ..< videoTileStatesForDisplay.count {
            if let tileState = videoTileStatesForDisplay[index] {
                currentMeetingSession?.audioVideo.pauseRemoteVideoTile(tileId: tileState.tileId)
            }
        }
        currentMeetingSession?.audioVideo.startRemoteVideo()
        showVideoOrScreen(isVideo: false)
    }

    // MARK: IBAction functions

    @IBAction func moreButtonClicked(_: UIButton) {
//        moreButton.isSelected = !moreButton.isSelected
//        attendeesButton.isSelected = !moreButton.isSelected
//        rosterTable.isHidden = !moreButton.isSelected
//        rosterTable.reloadData()

        // TODO: This will be add back with a separate table view
    }

    @IBAction func muteButtonClicked(_: UIButton) {
        muteButton.isSelected = !muteButton.isSelected
        if muteButton.isSelected {
            if let muted = currentMeetingSession?.audioVideo.realtimeLocalMute() {
                logger.info(msg: "Microphone has been muted \(muted)")
            }
        } else {
            if let unmuted = currentMeetingSession?.audioVideo.realtimeLocalUnmute() {
                logger.info(msg: "Microphone has been unmuted \(unmuted)")
            }
        }
    }

    @IBAction func deviceButtonClicked(_: UIButton) {
        guard let currentMeetingSession = currentMeetingSession else {
            return
        }
        let optionMenu = UIAlertController(title: nil, message: "Choose Audio Device", preferredStyle: .actionSheet)

        for inputDevice in currentMeetingSession.audioVideo.listAudioDevices() {
            let deviceAction = UIAlertAction(
                title: inputDevice.label,
                style: .default,
                handler: { _ in self.currentMeetingSession?.audioVideo.chooseAudioDevice(mediaDevice: inputDevice)
                }
            )
            optionMenu.addAction(deviceAction)
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        optionMenu.addAction(cancelAction)

        present(optionMenu, animated: true, completion: nil)
    }

    @IBAction func cameraButtonClicked(_: UIButton) {
        cameraButton.isSelected = !cameraButton.isSelected
        if cameraButton.isSelected {
            setupVideoEnv()
        } else {
            currentMeetingSession?.audioVideo.stopLocalVideo()
        }
    }

    @IBAction func screenButtonClicked(_: UIButton) {
        screenButton.isSelected = !screenButton.isSelected
        if screenButton.isSelected {
            startScreenShare()
        } else {
            startRemoteVideo()
        }
    }

    @IBAction func attendeesButtonClicked(_: UIButton) {
        attendeesButton.isSelected = !attendeesButton.isSelected
        moreButton.isSelected = !attendeesButton.isSelected
        rosterTable.isHidden = !attendeesButton.isSelected
        rosterTable.reloadData()
    }

    @IBAction func leaveButtonClicked(_: UIButton) {
        leaveMeeting()
    }

    @objc func onTileButtonClicked(_ sender: UIButton) {
        if sender.tag == 0 {
            switchCameraClicked()
        } else {
            sender.isSelected = !sender.isSelected
            toggleVideo(index: sender.tag, selected: sender.isSelected)
        }
    }

    private func switchCameraClicked() {
        currentMeetingSession?.audioVideo.switchCamera()
        if let tileState = videoTileStatesForDisplay[0],
            let indexPath = videoTileIdToIndexPath[tileState.tileId],
            let selfVideoTileCell = videoCollection.cellForItem(at: indexPath) as? VideoTileCell {
            if let selfVideoTileView = selfVideoTileCell.contentView as? DefaultVideoRenderView {
                selfVideoTileView.mirror = !selfVideoTileView.mirror
            }
        }
        logger.info(msg:
            "currentDevice \(currentMeetingSession?.audioVideo.getActiveCamera()?.description ?? "No device")")
    }

    private func toggleVideo(index: Int, selected: Bool) {
        if let tileState = videoTileStatesForDisplay[index], !tileState.isLocalTile {
            if selected {
                currentMeetingSession?.audioVideo.pauseRemoteVideoTile(
                    tileId: tileState.tileId
                )
            } else {
                currentMeetingSession?.audioVideo.resumeRemoteVideoTile(
                    tileId: tileState.tileId
                )
            }
        }
    }

    private func logAttendee(attendeeInfo: [AttendeeInfo], action: String) {
        for currentAttendeeInfo in attendeeInfo {
            let attendeeId = currentAttendeeInfo.attendeeId
            if !rosterModel.contains(attendeeId: attendeeId) {
                logger.error(msg: "Cannot find attendee with attendee id \(attendeeId)" +
                    " external user id \(currentAttendeeInfo.externalUserId): \(action)")
                continue
            }
            logger.info(msg: "\(rosterModel.getAttendeeName(for: attendeeId) ?? "nil"): \(action)")
        }
    }

    private func leaveMeeting() {
        currentMeetingSession?.audioVideo.stop()
        removeSubscriptionToAttendeeChangeHandler()
        DispatchQueue.main.async {
            self.dismiss(animated: true, completion: nil)
        }
    }

    @objc func setFullScreen(_: UITapGestureRecognizer? = nil) {
        if rosterTable.isHidden == false {
            rosterTable.isHidden = true
            attendeesButton.isSelected = false
            moreButton.isSelected = false
        } else if UIDevice.current.orientation.isLandscape {
            isFullScreen = !isFullScreen
            controlView.isHidden = isFullScreen
        }
    }
}

// MARK: AudioVideoObserver

extension MeetingViewController: AudioVideoObserver {
    func connectionDidRecover() {
        notify(msg: "Connection quality has recovered")
    }

    func connectionDidBecomePoor() {
        notify(msg: "Connection quality has become poor")
    }

    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        logger.info(msg: "Video stopped \(sessionStatus.statusCode)")
    }

    func audioSessionDidStartConnecting(reconnecting: Bool) {
        notify(msg: "Audio started connecting. Reconnecting: \(reconnecting)")
    }

    func audioSessionDidStart(reconnecting: Bool) {
        notify(msg: "Audio successfully started. Reconnecting: \(reconnecting)")
    }

    func audioSessionDidDrop() {
        notify(msg: "Audio Session Dropped")
    }

    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {
        logger.info(msg: "Audio stopped for a reason: \(sessionStatus.statusCode)")
        if sessionStatus.statusCode != .ok {
            leaveMeeting()
        }
    }

    func audioSessionDidCancelReconnect() {
        notify(msg: "Audio cancelled reconnecting")
    }

    func videoSessionDidStartConnecting() {
        logger.info(msg: "Video connecting")
    }

    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {
        switch sessionStatus.statusCode {
        case .videoAtCapacityViewOnly:
            notify(msg: "Maximum concurrent video limit reached! Failed to start local video.")
        default:
            logger.info(msg: "Video started \(sessionStatus.statusCode)")
        }
    }
}

// MARK: RealtimeObserver

extension MeetingViewController: RealtimeObserver {
    private func removeAttendeesAndReload(attendeeInfo: [AttendeeInfo]) {
        let attendeeIds = attendeeInfo.map { $0.attendeeId }
        rosterModel.removeAttendees(attendeeIds)
        rosterTable.reloadData()
    }

    func attendeesDidLeave(attendeeInfo: [AttendeeInfo]) {
        logAttendee(attendeeInfo: attendeeInfo, action: "Left")
        removeAttendeesAndReload(attendeeInfo: attendeeInfo)
    }

    func attendeesDidDrop(attendeeInfo: [AttendeeInfo]) {
        for attendee in attendeeInfo {
            notify(msg: "\(attendee.externalUserId) dropped")
        }

        removeAttendeesAndReload(attendeeInfo: attendeeInfo)
    }

    func attendeesDidMute(attendeeInfo: [AttendeeInfo]) {
        logAttendee(attendeeInfo: attendeeInfo, action: "Muted")
    }

    func attendeesDidUnmute(attendeeInfo: [AttendeeInfo]) {
        logAttendee(attendeeInfo: attendeeInfo, action: "Unmuted")
    }

    func volumeDidChange(volumeUpdates: [VolumeUpdate]) {
        for currentVolumeUpdate in volumeUpdates {
            let attendeeId = currentVolumeUpdate.attendeeInfo.attendeeId
            rosterModel.updateVolume(attendeeId: attendeeId, volume: currentVolumeUpdate.volumeLevel)
        }
        rosterTable.reloadData()
    }

    func signalStrengthDidChange(signalUpdates: [SignalUpdate]) {
        for currentSignalUpdate in signalUpdates {
            let attendeeId = currentSignalUpdate.attendeeInfo.attendeeId
            rosterModel.updateSignal(attendeeId: attendeeId, signal: currentSignalUpdate.signalStrength)
        }
        rosterTable.reloadData()
    }

    func attendeesDidJoin(attendeeInfo: [AttendeeInfo]) {
        var newAttendees = [RosterAttendee]()
        for currentAttendeeInfo in attendeeInfo {
            let attendeeId = currentAttendeeInfo.attendeeId
            if !rosterModel.contains(attendeeId: attendeeId) {
                let attendeeName = RosterModel.convertAttendeeName(from: currentAttendeeInfo)
                let newAttendee = RosterAttendee(attendeeId: attendeeId,
                                                 attendeeName: attendeeName,
                                                 volume: .notSpeaking,
                                                 signal: .high)
                newAttendees.append(newAttendee)
            }
        }
        rosterModel.addAttendees(newAttendees)
        rosterTable.reloadData()
    }
}

// MARK: MetricsObserver

extension MeetingViewController: MetricsObserver {
    func metricsDidReceive(metrics: [AnyHashable: Any]) {
        guard let observableMetrics = metrics as? [ObservableMetric: Any] else {
            logger.error(msg: "The received metrics \(metrics) is not of type [ObservableMetric: Any].")
            return
        }
        metricsDict.update(dict: metrics)
        logger.info(msg: "Media metrics have been received: \(observableMetrics)")
        rosterTable.reloadData()
    }
}

// MARK: DeviceChangeObserver

extension MeetingViewController: DeviceChangeObserver {
    func audioDeviceDidChange(freshAudioDeviceList: [MediaDevice]) {
        let deviceLabels: [String] = freshAudioDeviceList.map { device in "* \(device.label)" }
        view.makeToast("Device availability changed:\nAvailable Devices:\n\(deviceLabels.joined(separator: "\n"))")
    }
}

// MARK: VideoTileObserver

extension MeetingViewController: VideoTileObserver {
    func videoTileDidAdd(tileState: VideoTileState) {
        logger.info(msg: "Adding Video Tile tileId: \(tileState.tileId)" +
            " attendeeId: \(String(describing: tileState.attendeeId))")
        if tileState.isContent {
            currentMeetingSession?.audioVideo.bindVideoView(videoView: screenRenderView, tileId: tileState.tileId)
            screenRenderView.isHidden = false
            screenViewLabel.isHidden = true
        } else {
            if tileState.isLocalTile {
                videoTileStates[0] = tileState
            } else {
                videoTileStates.append(tileState)
            }

            videoTileStatesForDisplay = videoTileStates[...getMaxIndexOfVisibleVideoTiles()]
            videoCollection?.reloadData()
        }
    }

    func videoTileDidRemove(tileState: VideoTileState) {
        logger.info(msg: "Removing Video Tile tileId: \(tileState.tileId)" +
            " attendeeId: \(String(describing: tileState.attendeeId))")
        currentMeetingSession?.audioVideo.unbindVideoView(tileId: tileState.tileId)
        videoTileIdToIndexPath[tileState.tileId] = nil

        if tileState.isContent {
            screenRenderView.isHidden = true
            screenViewLabel.isHidden = false
        } else if tileState.isLocalTile {
            videoTileStates[0] = nil
        } else if let tileStateIndex = videoTileStates.firstIndex(of: tileState) {
            videoTileStates.remove(at: tileStateIndex)
        }

        videoTileStatesForDisplay = videoTileStates[...getMaxIndexOfVisibleVideoTiles()]
        videoCollection?.reloadData()
    }

    func videoTileDidPause(tileState: VideoTileState) {
        let attendeeId = tileState.attendeeId ?? "unkown"
        let attendeeName = rosterModel.getAttendeeName(for: attendeeId) ?? ""
        if tileState.pauseState == .pausedForPoorConnection {
            view.makeToast("Video for attendee \(attendeeName) " +
                " has been paused for poor network connection," +
                " video will automatically resume when connection improves")
        } else {
            view.makeToast("Video for attendee \(attendeeName) " +
                " has been paused")
        }
    }

    func videoTileDidResume(tileState: VideoTileState) {
        let attendeeId = tileState.attendeeId ?? "unkown"
        let attendeeName = rosterModel.getAttendeeName(for: attendeeId) ?? ""
        view.makeToast("Video for attendee \(attendeeName) has been unpaused")
    }
}

// MARK: ActiveSpeakerObserver

extension MeetingViewController: ActiveSpeakerObserver {
    var observerId: String {
        return uuid
    }

    func activeSpeakerDidDetect(attendeeInfo: [AttendeeInfo]) {
        rosterModel.updateActiveSpeakers(attendeeInfo.map { $0.attendeeId })
        rosterTable.reloadData()
    }
}

// MARK: UICollectionView Delegate

extension MeetingViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in _: UICollectionView) -> Int {
        // Only one section for all video tiles
        return 1
    }

    func collectionView(_: UICollectionView,
                        numberOfItemsInSection _: Int) -> Int {
        return videoTileStatesForDisplay.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: videoTileCellReuseIdentifier, for: indexPath
        ) as? VideoTileCell else {
            return VideoTileCell()
        }

        // Reset the reusable cell as it may contains stale data from previous usage

        cell.accessibilityIdentifier = nil
        cell.attendeeName.isHidden = false
        cell.backgroundColor = .systemGray
        cell.contentView.backgroundColor = .systemGray
        cell.contentView.isHidden = false
        cell.isHidden = true
        cell.onTileButton.addTarget(self, action:
            #selector(onTileButtonClicked), for: .touchUpInside)
        cell.onTileButton.imageView?.contentMode = UIView.ContentMode.scaleAspectFill
        cell.onTileButton.tag = indexPath.item
        cell.shadedView.isHidden = false
        cell.videoRenderView.backgroundColor = .systemGray
        cell.videoRenderView.isHidden = true
        cell.videoRenderView.mirror = false

        if let tileState = videoTileStatesForDisplay[indexPath.item] {
            var attendeeName = ""

            cell.backgroundColor = .clear
            cell.isHidden = false
            cell.onTileButton.isHidden = false
            cell.onTileImage.isHidden = true
            cell.videoRenderView.isHidden = false

            if tileState.isLocalTile {
                cell.onTileButton.setImage(
                    UIImage(named: "switch-camera")?.withRenderingMode(.alwaysTemplate), for: .normal
                )
                attendeeName = selfName ?? attendeeName
                if currentMeetingSession?.audioVideo.getActiveCamera()?.type == .videoFrontCamera {
                    cell.videoRenderView.mirror = true
                }
            } else {
                cell.onTileButton.setImage(
                    UIImage(named: "pause-video")?.withRenderingMode(.alwaysTemplate), for: .normal
                )
                cell.onTileButton.setImage(
                    UIImage(named: "resume-video")?.withRenderingMode(.alwaysTemplate), for: .selected
                )
                if let attendeeId = tileState.attendeeId, let name = rosterModel.getAttendeeName(for: attendeeId) {
                    attendeeName = name
                }
            }

            cell.onTileButton.tintColor = .white
            cell.attendeeName.text = attendeeName
            cell.accessibilityIdentifier = "\(attendeeName) video tile"

            currentMeetingSession?.audioVideo.bindVideoView(
                videoView: cell.videoRenderView,
                tileId: tileState.tileId
            )
            videoTileIdToIndexPath[tileState.tileId] = indexPath
        } else {
            cell.attendeeName.text = "Turn on your video"
            cell.isHidden = false
            cell.onTileButton.isHidden = true
            cell.onTileImage.isHidden = false
        }

        return cell
    }

    func collectionView(_: UICollectionView,
                        layout _: UICollectionViewLayout,
                        sizeForItemAt _: IndexPath) -> CGSize {
        var width = view.frame.width
        var height = view.frame.height
        if UIApplication.shared.statusBarOrientation.isLandscape {
            height /= 2.0
            width = height / 9.0 * 16.0
        } else {
            height = width / 16.0 * 9.0
        }
        return CGSize(width: width, height: height)
    }

    func collectionView(_: UICollectionView,
                        layout _: UICollectionViewLayout,
                        insetForSectionAt _: Int) -> UIEdgeInsets {
        return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func collectionView(_: UICollectionView,
                        layout _: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt _: Int) -> CGFloat {
        return 8
    }
}

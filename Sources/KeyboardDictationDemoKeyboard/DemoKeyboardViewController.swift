import AVFoundation
import OSLog
#if SWIFT_PACKAGE
import CalciCredentials
#endif
import UIKit

private let log = Logger(subsystem: "net.stupidtech.keyboard-dictation-demo.keyboard", category: "dictation")

@MainActor
private func trace(_ message: String) {
    let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("calci-diagnostics.log")
    let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
    var data = (try? Data(contentsOf: url)) ?? Data()
    if data.count > 65_536 { data = Data(data.suffix(32_768)) }
    data.append(contentsOf: line.utf8)
    try? data.write(to: url, options: .atomic)
    log.info("\(message, privacy: .public)")
}

@objc(DemoKeyboardViewController)
final class DemoKeyboardViewController: UIInputViewController {
    // Dimensions of the compact panel, excluding the iOS strip below it.
    private enum Panel {
        static let height: CGFloat = 144
        static let sideInset: CGFloat = 12
        static let voiceDiameter: CGFloat = 82
        static let meterSize = CGSize(width: 76, height: 24)
        static let actionHeight: CGFloat = 44
        static let actionWidth: CGFloat = 70
        static let panelColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1)
                : UIColor(red: 0.84, green: 0.87, blue: 0.92, alpha: 1)
        }
        static let voiceColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.25, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
        static let sendColor = UIColor(red: 0.18, green: 0.41, blue: 0.98, alpha: 1)
    }

    private let capture = WebAudioCapture()
    private let dictateButton = UIButton(type: .custom)
    private let microphoneIcon = UIImageView(image: UIImage(
        systemName: "mic.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 31, weight: .medium)
    ))
    private let meter = UIView()
    private let gestureHint = UILabel()
    private var isDictationTouchDown = false
    private var holdOrigin = CGPoint.zero
    private var recordingDocument: UUID?
    private var deletingFromHold = false
    private let wave = CAShapeLayer()
    private let waveFade = CAGradientLayer()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureIcon = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
    private var failureClear: Task<Void, Never>?
    private var failureMessage: String?
    private let pressFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let releaseFeedback = UIImpactFeedbackGenerator(style: .light)
    private let nextKeyboardButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var keyboardHand: KeyboardHand?
    private var handConstraints: [NSLayoutConstraint] = []
    private var clearTextTask: Task<Void, Never>?

    private final class Turn {
        let id = UUID().uuidString.prefix(8)
        let audio: AsyncStream<Data>.Continuation
        var task: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var connection: PreparedConnection?
        var text = ""
        var done = false
        init(_ audio: AsyncStream<Data>.Continuation) { self.audio = audio }
    }
    private var turns: [Turn] = []
    private var pendingSendDocument: UUID?
    private var recording: Turn?
    /// Text currently inserted for the in-flight partial result, replaced as results refine.
    private var insertedPartial = ""
    private var expectedContext: String?
    private var capturedBytes = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        trace("keyboard loaded")
        configureView()
        capture.onReady = { [weak self] in trace("web capture ready"); self?.render() }
        capture.onStarted = { trace("microphone started") }
        capture.onAudio = { [weak self] data, bands in
            guard let self else { return }
            if self.capturedBytes == 0 { trace("first captured frame bytes=\(data.count)") }
            self.capturedBytes += data.count
            self.recording?.audio.yield(data)
            self.updateMeter(bands)
        }
        capture.onEnded = { [weak self] reason in
            trace("capture ended: \(reason)")
            guard reason != "stopped" else { return }
            log.error("Microphone capture interrupted")
            if let self, let turn = self.recording { self.showFailure("麦克风中断"); self.finish(turn) }
        }
        capture.attach(to: view)
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDictationTouchDown = false
        stopRepeatingDelete()
        discardStandby()
        standbyState = "keyboard-hidden"
        finishRecognition()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardHand()
        syncKeyboardAppearance()
        updateReturnButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prepareStandby()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncKeyboardAppearance()
        updateReturnButton()
    }

    deinit {
        MainActor.assumeIsolated {
            stopRepeatingDelete()
            capture.tearDown()
        }
    }

    // MARK: - Dictation

    @objc private func beginDictationTouch() {
        guard recording == nil, !isDictationTouchDown else { return }
        isDictationTouchDown = true
        // A small pulse acknowledges the touch before any audio is captured.
        drawMeter([4, 8, 20, 39, 56, 46, 28, 18, 10, 6, 4, 2])
        if !UIAccessibility.isReduceMotionEnabled {
            let pulse = CABasicAnimation(keyPath: "transform.scale.y")
            pulse.fromValue = 0.35
            pulse.toValue = 1
            pulse.duration = 0.14
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wave.add(pulse, forKey: "touchPulse")
        }
    }

    @objc private func endDictationTouch() {
        isDictationTouchDown = false
        updateMeterVisibility()
    }

    @objc private func holdToDictate(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDictationTouchDown = false
            defer { updateMeterVisibility() }
            stopRepeatingDelete()
            holdOrigin = gesture.location(in: view)
            trace("hold began ready=\(capture.isReady) capturing=\(capture.isCapturing) pending=\(turns.count)")
            guard capture.isReady, !capture.isCapturing, recording == nil else { return }
            startDictation()
            if capture.isCapturing {
                pressFeedback.impactOccurred()
                releaseFeedback.prepare()
            }
        case .changed:
            guard recording != nil else { return }
            // Sideways movement and small shifts are normal while holding.
            let distance = holdOrigin.y - gesture.location(in: view).y
            if distance >= 64 {
                cancelDictation()
                releaseFeedback.impactOccurred()
            }
        case .ended:
            guard capture.isCapturing else { return }
            stopDictation()
            releaseFeedback.impactOccurred()
            pressFeedback.prepare()
        case .cancelled, .failed:
            endDictationTouch()
            cancelDictation()
        default:
            break
        }
    }

    private func cancelDictation() {
        guard let turn = recording else { return }
        pendingSendDocument = nil
        // Only the first turn can have inserted a partial result. Never delete
        // text after the user moved the cursor or switched to another document.
        if turns.first === turn {
            guard recordingDocument == textDocumentProxy.documentIdentifier,
                  textDocumentProxy.documentContextBeforeInput == expectedContext else {
                finishRecognition()
                return
            }
            replacePartial(with: "")
        }
        turn.text = ""
        finish(turn)
        prepareStandby()
        UIAccessibility.post(notification: .announcement, argument: "已取消")
    }

    private var standbyState = "none"
    private var standbySince = ProcessInfo.processInfo.systemUptime
    private var standby: PreparedConnection?
    private var idleTimeout: Task<Void, Never>?

    private func discardStandby() {
        idleTimeout?.cancel()
        standby?.close()
        standby = nil
    }

    private func prepareStandby() {
        guard standby == nil, hasFullAccess, AVAudioApplication.shared.recordPermission == .granted,
              let key = APIKeyStore.read(), !key.isEmpty else { return }
        let candidate = PreparedConnection(key: key)
        standbyState = "connecting"
        standbySince = ProcessInfo.processInfo.systemUptime
        standby = candidate
        idleTimeout = Task { [weak self] in
            do {
                try await candidate.ready.value
                guard self?.standby === candidate else { return }
                self?.standbyState = "ready"
                trace("preconnected")
                try await Task.sleep(for: .seconds(25))
                guard self?.standby === candidate else { return }
                self?.standbyState = "expired"
            } catch {
                guard self?.standby === candidate else { return }
                self?.standbyState = "failed"
                trace("connection=\(candidate.id) standby failed code=\((error as NSError).code)")
            }
            guard self?.standby === candidate else { return }
            self?.discardStandby()
        }
    }

    private func startDictation() {
        pendingSendDocument = nil
        trace("permissions fullAccess=\(hasFullAccess) microphone=\(AVAudioApplication.shared.recordPermission.rawValue)")
        guard hasFullAccess, AVAudioApplication.shared.recordPermission == .granted else {
            log.error("Keyboard or microphone permission missing")
            return
        }
        guard let key = APIKeyStore.read(), !key.isEmpty else {
            trace("OpenAI key unavailable")
            return
        }
        failureClear?.cancel()
        failureMessage = nil
        capturedBytes = 0
        let preflight = standbyState
        let age = Int((ProcessInfo.processInfo.systemUptime - standbySince) * 1000)
        standbyState = "consumed"
        let connection = standby ?? PreparedConnection(key: key)
        standby = nil
        idleTimeout?.cancel()
        let (frames, continuation) = AsyncStream<Data>.makeStream()
        let turn = Turn(continuation)
        if turns.isEmpty { expectedContext = textDocumentProxy.documentContextBeforeInput }
        turn.connection = connection
        trace("turn=\(turn.id) connection=\(connection.id) hold accepted standby=\(preflight) msSinceStandbyStart=\(age)")
        recordingDocument = textDocumentProxy.documentIdentifier
        recording = turn
        updateFeedback()
        turns.append(turn)
        let document = textDocumentProxy.documentIdentifier
        turn.task = Task { [weak self] in
            defer { connection.close() }
            await withTaskCancellationHandler {
                var sender: Task<Void, Error>?
                defer { sender?.cancel() }
                do {
                    do {
                        try await connection.ready.value
                    } catch {
                        try Task.checkCancellation()
                        let e = error as NSError
                        let retryable = [NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]
                        guard e.domain == NSURLErrorDomain, retryable.contains(e.code) else { throw error }
                        connection.close()
                        try await Task.sleep(for: .milliseconds(200))
                        let retry = PreparedConnection(key: key)
                        turn.connection = retry
                        trace("turn=\(turn.id) retry connection=\(retry.id)")
                        try await retry.ready.value
                    }
                    guard let socket = turn.connection?.socket else { throw CancellationError() }
                    try Task.checkCancellation()
                    trace("turn=\(turn.id) sender ready")
                    sender = Task { try await Self.sendAudio(frames, over: socket, turnID: String(turn.id)) }
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard case let .string(payload) = message else { continue }
                        let event = try JSONDecoder().decode(TranscriptionEvent.self, from: Data(payload.utf8))
                        guard let self, !Task.isCancelled, !turn.done else { break }
                        guard self.textDocumentProxy.documentIdentifier == document else { self.finishRecognition(); break }
                        guard self.textDocumentProxy.documentContextBeforeInput == self.expectedContext else {
                            trace("input position changed")
                            self.finishRecognition()
                            break
                        }
                        switch event.type {
                        case "conversation.item.input_audio_transcription.delta":
                            if let delta = event.delta { if turn.text.isEmpty { trace("turn=\(turn.id) first delta") }; turn.text += delta; self.flushTurns() }
                        case "conversation.item.input_audio_transcription.completed":
                            trace("turn=\(turn.id) final received")
                            if let final = event.transcript { turn.text = final; self.flushTurns() }
                        case "error", "conversation.item.input_audio_transcription.failed":
                            self.showFailure("转写失败")
                            trace("OpenAI error " + (event.error?.code ?? "unknown"))
                        default: continue
                        }
                        if ["conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.failed", "error"].contains(event.type) { break }
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.showFailure("连接失败")
                        let failure = error as NSError
                        trace("turn=\(turn.id) connection error domain=\(failure.domain) code=\(failure.code) description=\(failure.localizedDescription)")
                    }
                }
                turn.connection?.close()
                if !Task.isCancelled { self?.finish(turn) }
                sender?.cancel()
            } onCancel: {
                connection.close()
            }
        }
        capture.start()
    }

    nonisolated private static func sendAudio(_ frames: AsyncStream<Data>, over socket: URLSessionWebSocketTask, turnID: String) async throws {
        do {
            var sentFirst = false
            for await frame in frames {
                try Task.checkCancellation()
                try await socket.send(.string(#"{"type":"input_audio_buffer.append","audio":""# + frame.base64EncodedString() + #""}"#))
                if !sentFirst {
                    sentFirst = true
                    await MainActor.run { trace("turn=\(turnID) first audio sent") }
                }
            }
            try Task.checkCancellation()
            try await socket.send(.string(#"{"type":"input_audio_buffer.commit"}"#))
            await MainActor.run { trace("turn=\(turnID) commit sent") }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func stopDictation() {
        trace("hold released capturedBytes=\(capturedBytes)")
        guard let turn = recording else { return }
        recording = nil
        capture.stop()
        guard capturedBytes >= 4_800 else {
            trace("capture shorter than 100ms")
            finish(turn)
            return
        }
        turn.audio.finish()
        updateFeedback()
        prepareStandby()
        turn.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.showFailure("转写超时")
            self?.finish(turn)
        }
    }

    private func replacePartial(with text: String) {
        guard text != insertedPartial else { return }
        // Only rewrite the suffix that changed to minimise flicker in the host field.
        let common = zip(insertedPartial, text).prefix { $0 == $1 }.count
        for _ in 0..<(insertedPartial.count - common) { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(String(text.dropFirst(common)))
        trace("inserted transcript characters=\(text.count)")
        expectedContext = textDocumentProxy.documentContextBeforeInput
        insertedPartial = text
    }

    private func finish(_ turn: Turn) {
        guard !turn.done else { return }
        turn.done = true
        turn.connection?.close()
        turn.connection = nil
        turn.task?.cancel()
        turn.task = nil
        turn.timeout?.cancel()
        turn.timeout = nil
        turn.audio.finish()
        if recording === turn {
            recording = nil
            capture.stop()
        }
        flushTurns()
        if turns.isEmpty, let document = pendingSendDocument {
            pendingSendDocument = nil
            if document == textDocumentProxy.documentIdentifier,
               textDocumentProxy.returnKeyType == .send, textDocumentProxy.hasText {
                textDocumentProxy.insertText("\n")
            }
        }
        updateReturnButton()
        updateFeedback()
    }

    private func flushTurns() {
        guard textDocumentProxy.documentContextBeforeInput == expectedContext else {
            finishRecognition()
            return
        }
        while let first = turns.first {
            replacePartial(with: first.text)
            guard first.done else { return }
            turns.removeFirst()
            insertedPartial = ""
        }
    }

    private func finishRecognition() {
        pendingSendDocument = nil
        recording = nil
        for turn in turns {
            turn.done = true
            turn.connection?.close()
            turn.task?.cancel()
            turn.timeout?.cancel()
            turn.audio.finish()
        }
        turns.removeAll()
        capture.stop()
        insertedPartial = ""
        updateFeedback()
    }

    // MARK: - UI

    @objc private func beginDeleteTouch() {
        stopRepeatingDelete()
        deletingFromHold = false
    }

    @objc private func pressDelete() {
        guard !deletingFromHold, !capture.isCapturing, turns.isEmpty else { return }
        stopRepeatingDelete()
        textDocumentProxy.deleteBackward()
    }

    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !capture.isCapturing, turns.isEmpty else { return }
            stopRepeatingDelete()
            deletingFromHold = true
            let document = textDocumentProxy.documentIdentifier
            clearTextTask = Task { @MainActor [weak self] in
                let started = ProcessInfo.processInfo.systemUptime
                var clearing = false
                var emptyPasses = 0
                // Bound the operation even when a host does not expose its text.
                for _ in 0..<3000 {
                    guard let self, !Task.isCancelled,
                          self.textDocumentProxy.documentIdentifier == document,
                          !self.capture.isCapturing, self.turns.isEmpty else { return }
                    let proxy = self.textDocumentProxy
                    if !clearing && ProcessInfo.processInfo.systemUptime - started >= 1.2 {
                        clearing = true
                        self.gestureHint.text = "正在清空"
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    if clearing, let suffix = proxy.documentContextAfterInput, !suffix.isEmpty {
                        // Context may contain only one paragraph. Re-read after
                        // each move so text beyond that paragraph is included.
                        proxy.adjustTextPosition(byCharacterOffset: suffix.utf16.count)
                        try? await Task.sleep(for: .milliseconds(40))
                        continue
                    }
                    let empty = !proxy.hasText && (proxy.documentContextBeforeInput ?? "").isEmpty
                    emptyPasses = empty ? emptyPasses + 1 : 0
                    if emptyPasses >= 12 { break }
                    // Do not stop on a single empty context: hosts can briefly
                    // expose no text at a paragraph boundary or during refresh.
                    let batch = clearing ? min(24, max(1, proxy.documentContextBeforeInput?.count ?? 0)) : 1
                    for _ in 0..<batch { proxy.deleteBackward() }
                    try? await Task.sleep(for: .milliseconds(clearing ? 40 : 80))
                }
                self?.gestureHint.text = ""
            }
            gestureHint.text = "继续按住清空"
        case .ended, .cancelled, .failed:
            stopRepeatingDelete()
            // Keep suppressing touchUpInside for this release. The next
            // touchDown resets the flag before a new tap or hold.
        default: break
        }
    }

    private func stopRepeatingDelete() {
        clearTextTask?.cancel()
        clearTextTask = nil
        gestureHint.text = ""
    }

    @objc private func pressReturn() {
        guard recording == nil else { return }
        if !turns.isEmpty {
            if textDocumentProxy.returnKeyType == .send {
                pendingSendDocument = textDocumentProxy.documentIdentifier
            }
            return
        }
        textDocumentProxy.insertText("\n")
    }

    private func updateReturnButton() {
        let title: String
        switch textDocumentProxy.returnKeyType {
        case .send: title = "发送"
        case .search, .google, .yahoo: title = "搜索"
        case .go: title = "前往"
        case .done: title = "完成"
        case .next: title = "下一项"
        case .join: title = "加入"
        case .continue: title = "继续"
        case .route: title = "路线"
        case .emergencyCall: title = "紧急呼叫"
        default: title = "换行"
        }
        let isSubmission = title != "换行"
        returnButton.setTitle(isSubmission ? title : nil, for: .normal)
        returnButton.setImage(isSubmission ? nil : UIImage(systemName: "return"), for: .normal)
        returnButton.accessibilityLabel = title
        returnButton.tintColor = isSubmission ? .white : .label
        returnButton.setTitleColor(isSubmission ? .white : .label, for: .normal)
        returnButton.backgroundColor = isSubmission ? Panel.sendColor : .secondarySystemBackground
        returnButton.isEnabled = (recording == nil && !turns.isEmpty && textDocumentProxy.returnKeyType == .send) || textDocumentProxy.enablesReturnKeyAutomatically != true || textDocumentProxy.hasText
        returnButton.alpha = returnButton.isEnabled ? 1 : 0.5
    }

    private func configureView() {
        gestureHint.font = .preferredFont(forTextStyle: .caption1)
        gestureHint.textAlignment = .center
        gestureHint.textColor = .secondaryLabel
        gestureHint.isUserInteractionEnabled = false
        wave.frame = CGRect(origin: .zero, size: Panel.meterSize)
        wave.fillColor = nil
        wave.lineWidth = 2
        wave.lineCap = .round
        meter.isUserInteractionEnabled = false
        meter.accessibilityElementsHidden = true
        meter.clipsToBounds = true
        meter.layer.addSublayer(wave)
        waveFade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                           UIColor.black.cgColor, UIColor.clear.cgColor]
        waveFade.locations = [0, 0.15, 0.85, 1]
        waveFade.startPoint = CGPoint(x: 0, y: 0.5)
        waveFade.endPoint = CGPoint(x: 1, y: 0.5)
        meter.layer.mask = waveFade
        refreshTheme()
        let indicators: [UIView] = [microphoneIcon, spinner, failureIcon]
        for indicator in indicators {
            indicator.isUserInteractionEnabled = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            dictateButton.addSubview(indicator)
            NSLayoutConstraint.activate([indicator.centerXAnchor.constraint(equalTo: dictateButton.centerXAnchor),
                                         indicator.centerYAnchor.constraint(equalTo: dictateButton.centerYAnchor)])
        }
        failureIcon.tintColor = .secondaryLabel
        updateFeedback()
        dictateButton.layer.cornerRadius = Panel.voiceDiameter / 2
        dictateButton.layer.shadowColor = UIColor.black.cgColor
        dictateButton.layer.shadowOpacity = 0.14
        dictateButton.layer.shadowRadius = 4
        dictateButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        dictateButton.accessibilityLabel = "按住说话"
        dictateButton.addTarget(self, action: #selector(beginDictationTouch), for: .touchDown)
        dictateButton.addTarget(self, action: #selector(endDictationTouch), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        pressFeedback.prepare()
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdToDictate(_:)))
        hold.minimumPressDuration = 0.12
        hold.allowableMovement = .greatestFiniteMagnitude
        dictateButton.addGestureRecognizer(hold)

        nextKeyboardButton.accessibilityLabel = "切换键盘"
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        returnButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        returnButton.layer.cornerRadius = 10
        returnButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        returnButton.addTarget(self, action: #selector(pressReturn), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.accessibilityLabel = "删除"
        deleteButton.accessibilityHint = "轻点删除一个字，按住连续删除，继续按住清空输入框"
        deleteButton.tintColor = .label
        deleteButton.addTarget(self, action: #selector(beginDeleteTouch), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(pressDelete), for: .touchUpInside)
        let deleteHold = UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:)))
        deleteHold.minimumPressDuration = 0.4
        deleteButton.addGestureRecognizer(deleteHold)

        for subview in [dictateButton, meter, gestureHint, nextKeyboardButton, returnButton, deleteButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Size the extension's root view so the host gets back the space.
            view.heightAnchor.constraint(equalToConstant: Panel.height),
            gestureHint.centerXAnchor.constraint(equalTo: meter.centerXAnchor),
            gestureHint.centerYAnchor.constraint(equalTo: meter.centerYAnchor),
            gestureHint.widthAnchor.constraint(equalToConstant: 160),
            meter.centerXAnchor.constraint(equalTo: dictateButton.centerXAnchor),
            meter.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            meter.widthAnchor.constraint(equalToConstant: Panel.meterSize.width),
            meter.heightAnchor.constraint(equalToConstant: Panel.meterSize.height),

            dictateButton.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 8),
            dictateButton.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            dictateButton.widthAnchor.constraint(equalToConstant: Panel.voiceDiameter),
            dictateButton.heightAnchor.constraint(equalTo: dictateButton.widthAnchor),

            returnButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            returnButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Panel.actionWidth),
            returnButton.heightAnchor.constraint(equalToConstant: Panel.actionHeight),

            deleteButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            deleteButton.leadingAnchor.constraint(equalTo: returnButton.leadingAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: returnButton.trailingAnchor),
            deleteButton.heightAnchor.constraint(equalToConstant: Panel.actionHeight),

            nextKeyboardButton.centerYAnchor.constraint(equalTo: returnButton.centerYAnchor),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: Panel.actionHeight),
        ])
        applyKeyboardHand()
    }

    private func applyKeyboardHand() {
        let hand = KeyboardHand.read()
        guard hand != keyboardHand else { return }
        keyboardHand = hand
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.deactivate(handConstraints)
        switch hand {
        case .left:
            handConstraints = [
                returnButton.leftAnchor.constraint(equalTo: safeArea.leftAnchor, constant: Panel.sideInset),
                returnButton.rightAnchor.constraint(lessThanOrEqualTo: dictateButton.leftAnchor, constant: -8),
                nextKeyboardButton.rightAnchor.constraint(equalTo: safeArea.rightAnchor, constant: -Panel.sideInset),
            ]
        case .right:
            handConstraints = [
                returnButton.rightAnchor.constraint(equalTo: safeArea.rightAnchor, constant: -Panel.sideInset),
                returnButton.leftAnchor.constraint(greaterThanOrEqualTo: dictateButton.rightAnchor, constant: 8),
                nextKeyboardButton.leftAnchor.constraint(equalTo: safeArea.leftAnchor, constant: Panel.sideInset),
            ]
        }
        NSLayoutConstraint.activate(handConstraints)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        waveFade.frame = meter.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshTheme()
        }
    }

    private func syncKeyboardAppearance() {
        switch textDocumentProxy.keyboardAppearance {
        case .dark?: overrideUserInterfaceStyle = .dark
        case .light?: overrideUserInterfaceStyle = .light
        default: overrideUserInterfaceStyle = .unspecified
        }
        refreshTheme()
    }

    private func refreshTheme() {
        view.backgroundColor = Panel.panelColor
        nextKeyboardButton.tintColor = .label
        deleteButton.tintColor = .label
        microphoneIcon.tintColor = .secondaryLabel
        failureIcon.tintColor = .secondaryLabel
        wave.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        updateReturnButton()
        updateFeedback()
    }

    private func updateMeter(_ bands: [UInt8]) {
        guard recording != nil, bands.count == 12 else { return }
        wave.removeAnimation(forKey: "touchPulse")
        drawMeter(bands)
    }

    private func drawMeter(_ bands: [UInt8]) {
        let path = UIBezierPath()
        let spacing = Panel.meterSize.width / 24
        let centerY = Panel.meterSize.height / 2
        for i in 0..<24 {
            let band = i < 12 ? 11 - i : i - 12
            let level = min(1, CGFloat(bands[band]) / 255 * 1.5)
            let x = (CGFloat(i) + 0.5) * spacing
            let halfHeight = max(0.2, level * (centerY - 2))
            path.move(to: CGPoint(x: x, y: centerY - halfHeight))
            path.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.path = path.cgPath
        wave.isHidden = false
        CATransaction.commit()
    }

    private func showFailure(_ message: String) {
        pendingSendDocument = nil
        failureMessage = message
        failureClear?.cancel()
        failureClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.failureMessage = nil
            self?.updateFeedback()
        }
        updateFeedback()
    }

    private func updateMeterVisibility() {
        wave.isHidden = !isDictationTouchDown && recording == nil
        if wave.isHidden { wave.removeAllAnimations() }
    }

    private func updateFeedback() {
        updateReturnButton()
        updateMeterVisibility()
        let waiting = recording == nil && turns.contains { !$0.done }
        dictateButton.backgroundColor = waiting ? .systemRed : Panel.voiceColor
        spinner.color = .white
        if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        failureIcon.isHidden = recording != nil || waiting || failureMessage == nil
        microphoneIcon.isHidden = waiting || !failureIcon.isHidden
        dictateButton.accessibilityValue = recording != nil ? "录音中，上滑取消" : waiting ? "正在转写" : failureMessage
    }

    private func render() {
        updateReturnButton()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }
}

private struct TranscriptionEvent: Decodable {
    struct APIError: Decodable { let code: String? }
    let type: String
    let delta: String?
    let transcript: String?
    let error: APIError?
}

private final class ConnectionObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [id] in trace("connection=\(id) websocket opened") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        func elapsed(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "na" }
            return String(Int(end.timeIntervalSince(start) * 1000))
        }
        for metric in metrics.transactionMetrics {
            let dns = elapsed(metric.domainLookupStartDate, metric.domainLookupEndDate)
            let connect = elapsed(metric.connectStartDate, metric.connectEndDate)
            let tls = elapsed(metric.secureConnectionStartDate, metric.secureConnectionEndDate)
            let detail = "connection=\(id) network dnsMs=\(dns) connectIncludingTLSMs=\(connect) tlsMs=\(tls)"
            Task { @MainActor in trace(detail) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error as NSError? else { return }
        let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = "connection=\(id) completed error=\(e.domain)/\(e.code) underlying=\(underlying?.domain ?? "-")/\(underlying?.code ?? 0)"
        Task { @MainActor in trace(detail) }
    }
}

private final class PreparedConnection {
    let id = UUID().uuidString
    let socket: URLSessionWebSocketTask
    let ready: Task<Void, Error>
    private let session: URLSession

    init(key: String) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!, timeoutInterval: 15)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .ephemeral, delegate: ConnectionObserver(id), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.resume()
        ready = Task { [socket, id] in
            await MainActor.run { trace("connection=\(id) setup started") }
            let update = #"{"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"turn_detection":null,"transcription":{"model":"gpt-live-transcribe","delay":"minimal","languages":["zh-cn","en"],"prompt":"日常口述，主要使用中文，可能在同一句话中夹杂英文单词、短语或完整英文句子。"}}}}}"#
            try await socket.send(.string(update))
            await MainActor.run { trace("connection=\(id) configuration sent model=gpt-live-transcribe delay=minimal languages=zh-cn,en context=mixed-language-v1") }
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard case let .string(payload) = message else { continue }
                let event = try JSONDecoder().decode(TranscriptionEvent.self, from: Data(payload.utf8))
                if event.type == "session.updated" {
                    await MainActor.run { trace("connection=\(id) session ready") }
                    return
                }
                if event.type == "error" {
                    throw NSError(domain: "OpenAI", code: 1, userInfo: [NSLocalizedDescriptionKey: event.error?.code ?? "session rejected"])
                }
            }
            throw CancellationError()
        }
    }

    func close() {
        ready.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    deinit { close() }
}

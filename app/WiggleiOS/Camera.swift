import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable
final class Camera: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    var captureAngle: CGFloat = 90
    var isRunning = false
    var isCapturing = false
    var failure: String?
    var shutterCount = 0

    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "camera")
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var coordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var angleObservation: NSKeyValueObservation?
    @ObservationIgnored private var photos: [AVCapturePhoto] = []
    @ObservationIgnored private var completion: (([URL]) -> Void)?
    @ObservationIgnored private var cropRatio = 0.52

    var isLandscape: Bool {
        abs(captureAngle - 90) > 45
    }

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                report("Нет доступа к камере. Разрешите его в Настройках")
                return
            }
            queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        isRunning = false
        queue.async { self.session.stopRunning() }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.failure = message }
    }

    private func configureAndRun() {
        if device == nil {
            guard let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device)
            else {
                report("На этом iPhone нет пары из широкой и сверхширокой камер")
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                report("Не удалось настроить камеру")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
            output.isVirtualDeviceConstituentPhotoDeliveryEnabled = output.isVirtualDeviceConstituentPhotoDeliverySupported
            session.commitConfiguration()
            guard output.isVirtualDeviceConstituentPhotoDeliveryEnabled else {
                report("Камера не умеет снимать двумя объективами сразу")
                return
            }

            let fields = Dictionary(
                device.constituentDevices.map { ($0.deviceType, Double($0.activeFormat.videoFieldOfView)) },
                uniquingKeysWith: { first, _ in first })
            if let wide = fields[.builtInWideAngleCamera], let ultra = fields[.builtInUltraWideCamera], wide > 0, ultra > wide {
                cropRatio = tan(wide * .pi / 360) / tan(ultra * .pi / 360)
            }
            if let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first, (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = CGFloat(truncating: switchOver)
                device.unlockForConfiguration()
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            angleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) {
                [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { self?.captureAngle = angle }
            }
            self.coordinator = coordinator
            self.device = device
        }
        session.startRunning()
        DispatchQueue.main.async { self.isRunning = self.session.isRunning }
    }

    func capture(_ done: @escaping ([URL]) -> Void) {
        guard !isCapturing, let device else { return }
        isCapturing = true
        shutterCount += 1
        completion = done
        let angle = captureAngle
        queue.async {
            self.photos = []
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            settings.virtualDeviceConstituentPhotoDeliveryEnabledDevices = device.constituentDevices
            settings.photoQualityPrioritization = .balanced
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil {
            photos.append(photo)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let result = Result { try write(photos) }
        photos = []
        DispatchQueue.main.async {
            self.isCapturing = false
            switch result {
            case .success(let urls):
                self.failure = nil
                self.completion?(urls)
            case .failure(let error):
                self.failure = error.localizedDescription
            }
            self.completion = nil
        }
    }

    private func write(_ photos: [AVCapturePhoto]) throws -> [URL] {
        guard let wide = photos.first(where: { $0.sourceDeviceType == .builtInWideAngleCamera }),
              let ultra = photos.first(where: { $0.sourceDeviceType == .builtInUltraWideCamera }),
              let wideData = wide.fileDataRepresentation(),
              let ultraImage = ultra.cgImageRepresentation()
        else { throw WiggleError("Камера вернула не оба снимка, попробуйте ещё раз") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let wideURL = folder.appendingPathComponent("0-wide.heic")
        try wideData.write(to: wideURL)

        let width = Double(ultraImage.width) * cropRatio
        let height = Double(ultraImage.height) * cropRatio
        let area = CGRect(
            x: (Double(ultraImage.width) - width) / 2, y: (Double(ultraImage.height) - height) / 2, width: width, height: height)
        let ultraURL = folder.appendingPathComponent("1-ultra.heic")
        guard let cropped = ultraImage.cropping(to: area.integral),
              let destination = CGImageDestinationCreateWithURL(ultraURL as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw WiggleError("Не удалось сохранить снимок сверхширокой камеры") }
        let orientation = ultra.metadata[kCGImagePropertyOrientation as String] ?? 1
        CGImageDestinationAddImage(destination, cropped, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WiggleError("Не удалось сохранить снимок сверхширокой камеры")
        }
        return [wideURL, ultraURL]
    }
}

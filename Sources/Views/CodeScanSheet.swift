import Foundation
import SwiftUI
import AVFoundation
import Vision
import PhotosUI

/// 授权码扫码页：AVFoundation 取景 + Vision 识别二维码。
/// 支持相机实时识别与「从图库选择二维码」两种方式。
/// 识别成功回调 onCode 后自动关闭（由调用方 dismiss）。
struct CodeScanSheet: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate,
                                   PHPickerViewControllerDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "qr-scan")
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false
        private var box: UIView?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video) else {
                fail("此设备没有摄像头")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
            } catch {
                fail("相机启动失败：\(error.localizedDescription)")
                return
            }

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            // 取景框
            let side = min(view.bounds.width, view.bounds.height) * 0.62
            let boxView = UIView(frame: CGRect(
                x: (view.bounds.width - side) / 2,
                y: (view.bounds.height - side) / 2 - 30,
                width: side, height: side))
            boxView.layer.borderColor = UIColor(red: 0.13, green: 0.84, blue: 0.93, alpha: 1).cgColor
            boxView.layer.borderWidth = 3
            boxView.layer.cornerRadius = 12
            view.addSubview(boxView)
            box = boxView

            let hint = UILabel()
            hint.text = "对准后台「授权码 → 二维码」"
            hint.textColor = .white
            hint.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            hint.textAlignment = .center
            hint.frame = CGRect(x: 0, y: view.bounds.height - 90, width: view.bounds.width, height: 40)
            view.addSubview(hint)

            // 图库入口：PHPicker 免相册权限，系统选择器代读
            let gallery = UIButton(type: .system)
            gallery.setTitle("🖼  从图库选择二维码", for: .normal)
            gallery.setTitleColor(UIColor(red: 0.13, green: 0.84, blue: 0.93, alpha: 1), for: .normal)
            gallery.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            gallery.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            gallery.frame = CGRect(x: 0, y: view.bounds.height - 50,
                                   width: view.bounds.width, height: 50)
            gallery.addTarget(self, action: #selector(pickFromGallery), for: .touchUpInside)
            view.addSubview(gallery)
        }

        // ── 图库选图 → Vision 识别 ──
        @objc private func pickFromGallery() {
            var cfg = PHPickerConfiguration()
            cfg.filter = .images
            cfg.selectionLimit = 1
            let picker = PHPickerViewController(configuration: cfg)
            picker.delegate = self
            present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !done, let item = results.first,
                  item.itemProvider.canLoadObject(ofClass: UIImage.self) else { return }
            item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let self, let img = obj as? UIImage else { return }
                self.decodeGalleryImage(img)
            }
        }

        private func decodeGalleryImage(_ img: UIImage) {
            // 统一成正立方向，大图限到 1024px 再识别
            let oriented = img.normalizedUp()
            guard let cg = oriented.cgImage else {
                showToast("图片读取失败")
                return
            }
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            let request = VNDetectBarcodesRequest { [weak self] req, _ in
                guard let self else { return }
                let text = (req.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue }.first
                DispatchQueue.main.async {
                    if let text, !self.done {
                        self.done = true
                        self.onCode?(AuthCode.normalize(text))
                        self.dismiss(animated: true)
                    } else if text == nil {
                        self.showToast("图片里没有识别到二维码，换一张试试")
                    }
                }
            }
            do {
                try handler.perform([request])
            } catch {
                showToast("识别失败：\(error.localizedDescription)")
            }
        }

        private func showToast(_ msg: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let label = UILabel()
                label.text = msg
                label.textColor = .white
                label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
                label.textAlignment = .center
                label.numberOfLines = 0
                label.layer.cornerRadius = 8
                label.clipsToBounds = true
                label.frame = CGRect(x: 30, y: 90, width: self.view.bounds.width - 60, height: 44)
                self.view.addSubview(label)
                UIView.animate(withDuration: 0.3, delay: 2.2, options: [],
                               animations: { label.alpha = 0 },
                               completion: { _ in label.removeFromSuperview() })
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            queue.async { [self] in
                if !session.isRunning { session.startRunning() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
            }
        }

        private func fail(_ msg: String) {
            DispatchQueue.main.async {
                let label = UILabel()
                label.text = msg
                label.textColor = .white
                label.numberOfLines = 0
                label.textAlignment = .center
                label.frame = CGRect(x: 20, y: 120, width: self.view.bounds.width - 40, height: 80)
                self.view.addSubview(label)
            }
        }

        // ── 逐帧识别 ──
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !done,
                  let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // 取景框内的区域，识别更快更准
            var region: CGRect?
            if let b = box?.frame, let p = preview {
                region = p.metadataOutputRectConverted(fromLayerRect: b)
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .left, options: [:])
            do {
                let request = VNDetectBarcodesRequest { [weak self] req, _ in
                    guard let self, !self.done else { return }
                    let codes = (req.results as? [VNBarcodeObservation])?
                        .compactMap { $0.payloadStringValue }
                    guard let text = codes?.first else { return }
                    self.done = true
                    let normalized = AuthCode.normalize(text)
                    DispatchQueue.main.async {
                        self.onCode?(normalized)
                        self.dismiss(animated: true)
                    }
                }
                if let r = region { request.regionOfInterest = r }
                try handler.perform([request])
            } catch {
                // 本帧失败，下一帧继续
            }
        }
    }
}

private extension UIImage {
    /// 依据当前 orientation 重新绘制成正立，并限制在 1024px 内；Vision 对方向敏感
    func normalizedUp() -> UIImage {
        let maxSide: CGFloat = 1024
        let ratio = min(1, maxSide / max(size.width, size.height))
        let w = size.width * ratio, h = size.height * ratio
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
            .image { _ in draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
}

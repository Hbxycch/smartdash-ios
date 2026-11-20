import SwiftUI
import UIKit
import PhotosUI

/// 品牌青（对齐 Android #00E5FF）；iOS 16 不能用系统 .cyan（色相不同）与 ShapeStyle.opacity
extension Color {
    static let brandCyan = Color(red: 0, green: 0.898, blue: 1.0)
}

// MARK: - 远程头像圆（AccountPage / SettingsPage / 车队成员行共用）

/// 有 avatarUrl 就拉远程头像（AvatarStore 三级缓存），否则回退首字母彩圆。
struct RemoteAvatarView: View {
    @EnvironmentObject var settings: AppSettings
    let url: String
    var diameter: CGFloat
    var fallbackText: String
    var fallbackColor: Color = .blue

    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(fallbackColor)
                    Text(fallbackText.isEmpty ? "·" : String(fallbackText.prefix(1)))
                        .font(.system(size: diameter * 0.42, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: diameter, height: diameter)
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: url) { _ in loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !url.isEmpty else { img = nil; return }
        let token = settings.userToken
        AvatarStore.shared.load(url, token: token) { result in img = result }
    }
}

// MARK: - 相机拍摄包装（车机/手机有摄像头才显示「拍照上传」）

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - 圆形裁剪（对齐设计稿图3 / Android AvatarCropActivity）

/// 全屏裁剪：图片可拖动/双指缩放，中央固定圆形框（even-odd 镂空圆外压暗），
/// 确定时把圆框位置反算回图片像素坐标，输出 512×512。
struct AvatarCropSheet: View {
    let source: UIImage
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = 260      // 圆框直径（屏幕坐标）
    private let outputPx: CGFloat = 512
    /// 图片中心比屏幕中心上移一点，给底部按钮留空间
    private let centerYOffset: CGFloat = -24

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let cx = geo.size.width / 2
                let cy = geo.size.height / 2 + centerYOffset
                ZStack {
                    Image(uiImage: source)
                        .resizable()
                        .scaledToFill()
                        .frame(width: imageFrame, height: imageFrame)
                        .scaleEffect(scale)
                        .offset(offset)
                        .position(x: cx, y: cy)
                        .gesture(dragGesture.simultaneously(with: pinchGesture))

                    // 圆外压暗：整屏矩形 + 圆形镂空（even-odd）
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addEllipse(in: CGRect(x: cx - cropSize / 2, y: cy - cropSize / 2,
                                                width: cropSize, height: cropSize))
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(evenOdd: true))

                    Circle()
                        .stroke(Color.brandCyan, lineWidth: 2.5)
                        .frame(width: cropSize, height: cropSize)
                        .position(x: cx, y: cy)
                }
            }

            VStack(spacing: 0) {
                Text("调整头像")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.top, 24)
                Spacer()
                Text("拖动调整位置 · 双指缩放 · 圆形区域内为最终头像")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 14)

                HStack(spacing: 14) {
                    Button("重选") { onCancel() }
                        .padding(.horizontal, 30).padding(.vertical, 12)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundColor(.white)
                    Button {
                        confirm()
                    } label: {
                        Text("确定并上传").fontWeight(.bold)
                    }
                    .padding(.horizontal, 30).padding(.vertical, 12)
                    .background(Color.brandCyan, in: Capsule())
                    .foregroundColor(.black)
                }
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 图片铺满圆框所需的基础边长：保证任意缩放前短边 ≥ cropSize，留出拖动余量
    private var imageFrame: CGFloat {
        let ratio = max(source.size.width / source.size.height, source.size.height / source.size.width)
        return cropSize * max(1.25, ratio)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                offset = CGSize(width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height)
            }
            .onEnded { _ in clampOffset() }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in scale = min(max(lastScale * v, 1), 6) }
            .onEnded { _ in
                lastScale = scale
                clampOffset()
            }
    }

    /// 把图片边缘约束进圆框内，避免拖出空白
    private func clampOffset() {
        let half = cropSize / 2
        let contentHalf = imageFrame * scale / 2
        let dx = max(min(offset.width, contentHalf - half), half - contentHalf)
        let dy = max(min(offset.height, contentHalf - half), half - contentHalf)
        offset = CGSize(width: dx, height: dy)
        lastOffset = offset
    }

    /// 裁剪：屏幕圆框位置反算回图片像素坐标，截出并归一到 512×512
    private func confirm() {
        let imgSize = source.size
        let base = imageFrame                        // scale=1 时的显示边长
        let shown = base * scale                     // 当前显示边长
        let pxPerPt = imgSize.width / shown          // 图片像素 / 屏幕点（scaledToFill 等比）

        // 圆框中心在图片像素坐标系里的位置（offset 为屏幕坐标位移）
        let centerInImage = CGPoint(x: imgSize.width / 2 - offset.width * pxPerPt,
                                    y: imgSize.height / 2 - offset.height * pxPerPt)
        let sidePx = cropSize * pxPerPt              // 圆框对应的图片像素边长
        var cropRect = CGRect(x: centerInImage.x - sidePx / 2,
                              y: centerInImage.y - sidePx / 2,
                              width: sidePx, height: sidePx)
        cropRect = cropRect.intersection(CGRect(origin: .zero, size: imgSize))
        guard cropRect.width >= 8, cropRect.height >= 8,
              let cg = source.cgImage?.cropping(to: cropRect) else { onCancel(); return }

        var out = UIImage(cgImage: cg, scale: 1, orientation: .up)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: outputPx, height: outputPx), true, 1)
        out.draw(in: CGRect(x: 0, y: 0, width: outputPx, height: outputPx))
        if let normalized = UIGraphicsGetImageFromCurrentImageContext() { out = normalized }
        UIGraphicsEndImageContext()

        onConfirm(out)
    }
}

// MARK: - 查看大图（设计稿图2 · 查看大图动作）

struct AvatarBigView: View {
    @EnvironmentObject var settings: AppSettings
    let url: String
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteAvatarView(url: url, diameter: 300, fallbackText: "")
        }
        .preferredColorScheme(.dark)
    }
}

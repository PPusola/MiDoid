import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {

    let payload: String
    let secondsLeft: Int

    @State private var isHidden = false

    private var progress: Double { Double(max(0, min(60, secondsLeft))) / 60.0 }

    private var ringColor: Color {
        switch progress {
        case 0.5...: return .syncGreen
        case 0.2...: return .syncYellow
        default:     return .syncRed
        }
    }

    private var qrImage: NSImage? { generateQR(from: payload) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Track ring (background)
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 4)
                    .frame(width: 192, height: 192)

                // Animated progress ring — same shape as QR, sits just outside it
                RoundedRectangle(cornerRadius: 18)
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 192, height: 192)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: secondsLeft)

                // QR image — inset so it sits fully inside the ring
                Group {
                    if let img = qrImage {
                        Image(nsImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)          // padding keeps QR inside the ring stroke
                            .frame(width: 192, height: 192)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.08))
                            .padding(12)
                            .frame(width: 192, height: 192)
                    }
                }
                .blur(radius: shouldBlur ? 18 : 0)
                .animation(.easeInOut(duration: 0.25), value: shouldBlur)

                // Expired overlay
                if secondsLeft <= 0 {
                    VStack(spacing: 6) {
                        Image(systemName: Icons.refresh)
                            .font(.system(size: 22))
                        Text("Refreshing…")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .frame(width: 192, height: 192)

            // Caption row — same width as the QR block
            HStack(spacing: 6) {
                if secondsLeft > 0 {
                    Image(systemName: Icons.clock)
                        .font(.caption2)
                    Text("Refreshes in \(secondsLeft)s")
                        .font(.caption)
                        .monospacedDigit()
                } else {
                    Text("Generating new QR…")
                        .font(.caption)
                }

                Spacer()

                Button {
                    withAnimation { isHidden.toggle() }
                } label: {
                    Image(systemName: isHidden ? Icons.eye : Icons.eyeSlash)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show QR code" : "Hide QR code")
            }
            .foregroundColor(.secondary)
            .frame(width: 192)
        }
    }

    private var shouldBlur: Bool { secondsLeft <= 0 || isHidden }

    private func generateQR(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

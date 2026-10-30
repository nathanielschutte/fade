import PencilKit
import SwiftUI

/// Drawing on a photo before it's sent (the web's draw.js): PencilKit's own
/// pens, colors, and undo over the picture. Done flattens the drawing into the
/// photo, so what's sealed and sent is one picture.
struct DrawOnPhoto: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let done: (UIImage) -> Void
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = fitted(image.size, in: geo.size)
                ZStack {
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    PencilCanvas(canvas: canvas).frame(width: size.width, height: size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.black)
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        done(flattened())
                        dismiss()
                    }
                }
            }
        }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func flattened() -> UIImage {
        Self.flatten(image, drawing: canvas.drawing, canvas: canvas.bounds.size)
    }

    /// The photo with the drawing on it, at the photo's own size (the drawing
    /// was made over the photo shown at `canvas` size).
    static func flatten(_ image: UIImage, drawing: PKDrawing, canvas: CGSize) -> UIImage {
        guard !drawing.strokes.isEmpty, canvas.width > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
            drawing.image(from: CGRect(origin: .zero, size: canvas), scale: max(1, image.size.width / canvas.width))
                .draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

/// PencilKit's canvas and tool picker, in SwiftUI.
struct PencilCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    @State private var picker = PKToolPicker()

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput  // a finger draws too, not only Apple Pencil
        canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 8)
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}
}

import PDFKit
import PencilKit
import SwiftUI

/// Swipeable pages for a whole setlist. While marking up, swiping is off so strokes never turn the page.
struct PageReader: UIViewControllerRepresentable {
    let pages: [StandPage]
    let store: Store
    @Binding var index: Int
    @ObservedObject var ink: InkSettings

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> StandPageViewController {
        let controller = StandPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 28])
        controller.delegate = context.coordinator
        controller.dataSource = context.coordinator
        controller.onTurn = { [weak coordinator = context.coordinator] delta in coordinator?.turn(delta) }
        controller.setViewControllers([context.coordinator.page(at: index)], direction: .forward, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: StandPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if (controller.dataSource == nil) != ink.isMarkingUp {
            controller.dataSource = ink.isMarkingUp ? nil : coordinator
        }
        if let shown = controller.viewControllers?.first as? PageController, shown.index != index {
            controller.setViewControllers([coordinator.page(at: index)], direction: index > shown.index ? .forward : .reverse, animated: true)
        }
        coordinator.applyInk(to: controller)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageReader

        init(_ parent: PageReader) { self.parent = parent }

        func page(at index: Int) -> PageController {
            let page = PageController(index: index, page: parent.pages[index], store: parent.store)
            page.onTurn = { [weak self] delta in self?.turn(delta) }
            page.ink = parent.ink
            return page
        }

        func turn(_ delta: Int) {
            parent.index = min(max(parent.index + delta, 0), parent.pages.count - 1)
        }

        func applyInk(to controller: UIPageViewController) {
            let shown = controller.viewControllers?.first as? PageController
            parent.ink.activePage = parent.ink.isMarkingUp ? shown : nil
            shown?.applyInk()
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? PageController)?.index, index > 0 else { return nil }
            return page(at: index - 1)
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? PageController)?.index, index < parent.pages.count - 1 else { return nil }
            return page(at: index + 1)
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let shown = controller.viewControllers?.first as? PageController else { return }
            parent.index = shown.index
        }
    }
}

/// Hosts the pages and listens for Bluetooth page-turn pedals, which send arrow, space or page keys.
final class StandPageViewController: UIPageViewController {
    var onTurn: ((Int) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let forward = [UIKeyCommand.inputRightArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputPageDown, " "]
        let back = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp]
        return (forward.map { ($0, #selector(turnForward)) } + back.map { ($0, #selector(turnBack)) }).map { input, action in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func turnForward() { onTurn?(1) }
    @objc private func turnBack() { onTurn?(-1) }
}

/// One chart page with a PencilKit canvas laid exactly over it.
final class PageController: UIViewController, PKCanvasViewDelegate {
    let index: Int
    let page: StandPage
    private let store: Store
    weak var ink: InkSettings?
    var onTurn: ((Int) -> Void)?

    private let paper = UIImageView()
    private let canvas = PKCanvasView()
    private var pageSize = CGSize(width: 612, height: 792)
    /// The handwriting in PDF points; the canvas holds it scaled to the screen.
    private var drawing = PKDrawing()
    private var scale: CGFloat = 0
    private var renderedSize = CGSize.zero
    private var isLoadingDrawing = false
    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    private var pendingSave: DispatchWorkItem?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(index: Int, page: StandPage, store: Store) {
        self.index = index
        self.page = page
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        view.addGestureRecognizer(tap)

        if page.isPlaceholder {
            showPlaceholder()
            return
        }
        if let pdfPage = PDFDocument(url: store.chartURL(songId: page.slot.songId))?.page(at: page.page) {
            let box = pdfPage.bounds(for: .cropBox)
            pageSize = pdfPage.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        }
        drawing = store.ink(songId: page.slot.songId, page: page.page)
        #if DEBUG
        // Screenshot hook: `-demoInk` circles the song title on the first page, in PDF points.
        if ProcessInfo.processInfo.arguments.contains("-demoInk"), page.page == 0, drawing.strokes.isEmpty {
            let points = (0...60).map { i -> PKStrokePoint in
                let angle = Double(i) / 60 * 2 * .pi
                return PKStrokePoint(location: CGPoint(x: 150 + 110 * cos(angle), y: 75 + 30 * sin(angle)), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemRed), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
            store.saveInk(drawing, songId: page.slot.songId, page: page.page)
        }
        #endif

        paper.backgroundColor = .white
        paper.contentMode = .scaleToFill
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.35
        paper.layer.shadowRadius = 12
        view.addSubview(paper)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Keep ink colors exact; PencilKit would otherwise invert dark ink in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.isUserInteractionEnabled = false
        view.addSubview(canvas)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !page.isPlaceholder else { return }
        let area = view.bounds.insetBy(dx: 10, dy: 10)
        guard area.width > 0, area.height > 0 else { return }
        let fit = min(area.width / pageSize.width, area.height / pageSize.height)
        let size = CGSize(width: pageSize.width * fit, height: pageSize.height * fit)
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        paper.frame = frame
        paper.layer.shadowPath = UIBezierPath(rect: paper.bounds).cgPath
        canvas.frame = frame
        if abs(fit - scale) > 0.0001 {
            scale = fit
            isLoadingDrawing = true
            canvas.drawing = drawing.transformed(using: CGAffineTransform(scaleX: fit, y: fit))
            isLoadingDrawing = false
            applyInk()
        }
        if abs(size.width - renderedSize.width) > 1 { render(size: size) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    private func render(size: CGSize) {
        renderedSize = size
        let url = store.chartURL(songId: page.slot.songId)
        let pageNumber = page.page
        let pixels = CGSize(width: size.width * traitCollection.displayScale, height: size.height * traitCollection.displayScale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Hold the document while drawing; a PDFPage can't draw once its document is gone.
            let document = PDFDocument(url: url)
            let image = document?.page(at: pageNumber)?.thumbnail(of: pixels, for: .cropBox)
            DispatchQueue.main.async { self?.paper.image = image }
        }
    }

    func applyInk() {
        guard let ink, !page.isPlaceholder else { return }
        canvas.isUserInteractionEnabled = ink.isMarkingUp
        if ink.isMarkingUp { canvas.tool = ink.pkTool(scale: scale) }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        // While playing, tap the left or right third of the screen to turn pages.
        guard ink?.isMarkingUp != true else { return }
        let x = gesture.location(in: view).x
        if x < view.bounds.width / 3 { onTurn?(-1) } else if x > view.bounds.width * 2 / 3 { onTurn?(1) }
    }

    // MARK: Drawing

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoadingDrawing, scale > 0 else { return }
        let updated = canvas.drawing.transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        undoStack.append(drawing)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        drawing = updated
        changed()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawing)
        show(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        show(next)
    }

    func clear() {
        guard !drawing.strokes.isEmpty else { return }
        undoStack.append(drawing)
        redoStack.removeAll()
        show(PKDrawing())
    }

    private func show(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        isLoadingDrawing = true
        canvas.drawing = newDrawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
        isLoadingDrawing = false
        changed()
    }

    private func changed() {
        ink?.refreshHistory()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveNow() {
        guard let pendingSave, !page.isPlaceholder else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        store.saveInk(drawing, songId: page.slot.songId, page: page.page)
    }

    private func showPlaceholder() {
        let title = UILabel()
        title.text = page.slot.title
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = .white
        let detail = UILabel()
        detail.text = "No chart yet. Attach one in Nash on the Mac, then resend the setlist."
        detail.font = .systemFont(ofSize: 17)
        detail.textColor = UIColor.white.withAlphaComponent(0.6)
        let icon = UIImageView(image: UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 48)))
        icon.tintColor = UIColor.white.withAlphaComponent(0.4)
        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
}

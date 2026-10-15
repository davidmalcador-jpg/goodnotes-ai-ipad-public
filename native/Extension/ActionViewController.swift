import UIKit
import SwiftUI
import PDFKit
import ImageIO

final class ActionViewController: UIViewController {
    private var model: ActionModel?
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ActionModel()
        self.model = model
        let content = ActionContentView(model: model) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard await model.finish() else { return }
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
        let hosting = UIHostingController(rootView: content)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        preferredContentSize = CGSize(width: 760, height: 900)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.receive(providers)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A settings, source or export sheet is not a closed extension.
        let hasPresentedSheet = presentedViewController != nil || children.contains { $0.presentedViewController != nil }
        if !hasPresentedSheet, let model {
            Task { @MainActor in _ = await model.finish() }
        }
    }
}

import UIKit

final class TerminalSelectionViewController: UIViewController {
    private let pendingText: String
    private let pendingAnchorRange: NSRange?

    var onDone: (() -> Void)?

    private lazy var textView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(text: String, anchorRange: NSRange?) {
        pendingText = text
        pendingAnchorRange = anchorRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        textView.text = pendingText
        view.addSubview(textView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: guide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(handleDone)
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()

        let nsText = textView.text as NSString
        if let range = pendingAnchorRange, NSMaxRange(range) <= nsText.length {
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        } else {
            textView.selectAll(nil)
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true) { [weak self] in
            self?.onDone?()
        }
    }
}

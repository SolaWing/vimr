/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import PureLayout
import RxSwift

class KeysPref: PrefPane, UiComponent, NSTextFieldDelegate {
  typealias StateType = AppState

  enum Action {
    case isLeftOptionMeta(Bool)
    case isRightOptionMeta(Bool)
    case drawMarkedTextInline(Bool)
  }

  override var displayName: String {
    "Keys"
  }

  override var pinToContainer: Bool {
    true
  }

  required init(source: Observable<StateType>, emitter: ActionEmitter, state: StateType) {
    self.emit = emitter.typedEmit()

    self.isLeftOptionMeta = state.mainWindowTemplate.isLeftOptionMeta
    self.isRightOptionMeta = state.mainWindowTemplate.isRightOptionMeta
    self.drawMarkedTextInline = state.mainWindowTemplate.drawMarkedTextInline

    super.init(frame: .zero)

    self.addViews()
    self.updateViews()

    source
      .observe(on: MainScheduler.instance)
      .subscribe(onNext: { state in
        if self.isLeftOptionMeta != state.mainWindowTemplate.isLeftOptionMeta
          || self.isRightOptionMeta != state.mainWindowTemplate.isRightOptionMeta
          || self.drawMarkedTextInline != state.mainWindowTemplate.drawMarkedTextInline
        {
          self.isLeftOptionMeta = state.mainWindowTemplate.isLeftOptionMeta
          self.isRightOptionMeta = state.mainWindowTemplate.isRightOptionMeta
          self.drawMarkedTextInline = state.mainWindowTemplate.drawMarkedTextInline

          self.updateViews()
        }
      })
      .disposed(by: self.disposeBag)
  }

  private let emit: (Action) -> Void
  private let disposeBag = DisposeBag()

  private var isLeftOptionMeta: Bool
  private var isRightOptionMeta: Bool
  private var drawMarkedTextInline: Bool

  private let isLeftOptionMetaCheckbox = NSButton(forAutoLayout: ())
  private let isRightOptionMetaCheckbox = NSButton(forAutoLayout: ())
  private let drawMarkedTextInlineCheckbox = NSButton(forAutoLayout: ())

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func updateViews() {
    self.isLeftOptionMetaCheckbox.boolState = self.isLeftOptionMeta
    self.isRightOptionMetaCheckbox.boolState = self.isRightOptionMeta
    self.drawMarkedTextInlineCheckbox.boolState = self.drawMarkedTextInline
  }

  private func addViews() {
    let paneTitle = self.paneTitleTextField(title: "Keys")

    let isLeftOptionMeta = self.isLeftOptionMetaCheckbox
    self.configureCheckbox(
      button: isLeftOptionMeta,
      title: "Use Left Option as Meta",
      action: #selector(KeysPref.isLeftOptionMetaAction(_:))
    )

    let isRightOptionMeta = self.isRightOptionMetaCheckbox
    self.configureCheckbox(
      button: isRightOptionMeta,
      title: "Use Right Option as Meta",
      action: #selector(KeysPref.isRightOptionMetaAction(_:))
    )

    let metaInfo = self.infoTextField(markdown: #"""
    When an Option key is set to Meta, then every input containing the corresponding Option key will\
    be passed through to Neovim. This means that you can use mappings like `<M-1>` in Neovim, but\
    cannot use the corresponding Option key for keyboard shortcuts containing `Option` or to enter\
    special characters like `µ` which is entered by `Option-M` (on the ABC keyboard layout).
    """#)

    let drawMarkedTextInline = self.drawMarkedTextInlineCheckbox
    self.configureCheckbox(
        button: drawMarkedTextInline,
        title: "Draw Marked Text Inline",
        action: #selector(KeysPref.drawMarkedTextInline(_:))
    )

    let drawMarkedTextInlineMetaInfo = self.infoTextField(markdown: #"""
    This option causes marked text to be rendered like normal text. disable this to avoid same marked text issue
    """#)

    self.addSubview(paneTitle)

    self.addSubview(isLeftOptionMeta)
    self.addSubview(isRightOptionMeta)
    self.addSubview(metaInfo)
    self.addSubview(drawMarkedTextInline)
    self.addSubview(drawMarkedTextInlineMetaInfo)

    paneTitle.autoPinEdge(toSuperviewEdge: .top, withInset: 18)
    paneTitle.autoPinEdge(toSuperviewEdge: .left, withInset: 18)
    paneTitle.autoPinEdge(toSuperviewEdge: .right, withInset: 18, relation: .greaterThanOrEqual)

    isLeftOptionMeta.autoPinEdge(.top, to: .bottom, of: paneTitle, withOffset: 18)
    isLeftOptionMeta.autoPinEdge(toSuperviewEdge: .left, withInset: 18)

    isRightOptionMeta.autoPinEdge(.top, to: .bottom, of: isLeftOptionMeta, withOffset: 5)
    isRightOptionMeta.autoPinEdge(toSuperviewEdge: .left, withInset: 18)

    metaInfo.autoPinEdge(.top, to: .bottom, of: isRightOptionMeta, withOffset: 5)
    metaInfo.autoPinEdge(toSuperviewEdge: .left, withInset: 18)

    drawMarkedTextInline.autoPinEdge(.top, to: .bottom, of: metaInfo, withOffset: 18)
    drawMarkedTextInline.autoPinEdge(toSuperviewEdge: .left, withInset: 18)

    drawMarkedTextInlineMetaInfo.autoPinEdge(.top, to: .bottom, of: drawMarkedTextInline, withOffset: 5)
    drawMarkedTextInlineMetaInfo.autoPinEdge(toSuperviewEdge: .left, withInset: 18)
  }
}

// MARK: - Actions

extension KeysPref {
  @objc func isLeftOptionMetaAction(_ sender: NSButton) {
    self.emit(.isLeftOptionMeta(sender.boolState))
  }

  @objc func isRightOptionMetaAction(_ sender: NSButton) {
    self.emit(.isRightOptionMeta(sender.boolState))
  }

  @objc func drawMarkedTextInline(_ sender: NSButton) {
    self.emit(.drawMarkedTextInline(sender.boolState))
  }
}

/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import Commons
import MessagePack
import os
import RxPack
import RxSwift
import Tabs

public class NvimView: NSView,
  UiBridgeConsumer,
  NSUserInterfaceValidations,
  NSTextInputClient
{
  // MARK: - Public

  public static let rpcEventName = "com.qvacua.NvimView"

  public static let minFontSize = 4.cgf
  public static let maxFontSize = 128.cgf
  public static let defaultFont = NSFont.userFixedPitchFont(ofSize: 12)!
  public static let defaultLinespacing = 1.cgf
  public static let defaultCharacterspacing = 1.cgf

  public static let minLinespacing = 0.5.cgf
  public static let maxLinespacing = 8.cgf

  public let usesCustomTabBar: Bool
  public let tabBar: TabBar<TabEntry>?

  public var isLeftOptionMeta = false
  public var isRightOptionMeta = false
  public var drawMarkedTextInline = true

  public let uuid = UUID()
  public let api = RxNeovimApi()

  public internal(set) var mode = CursorModeShape.normal
  public internal(set) var modeInfoList = [ModeInfo]()

  public internal(set) var theme = Theme.default

  public var trackpadScrollResistance = 5.cgf

  public var usesLiveResize = false

  public var usesLigatures = false {
    didSet {
      self.drawer.usesLigatures = self.usesLigatures
      self.markForRenderWholeView()
    }
  }

  public var drawsParallel = false {
    didSet { self.drawer.drawsParallel = self.drawsParallel }
  }

  public var linespacing: CGFloat {
    get { self._linespacing }

    set {
      guard newValue >= NvimView.minLinespacing, newValue <= NvimView.maxLinespacing else {
        return
      }

      self._linespacing = newValue
      self.updateFontMetaData(self._font)
    }
  }

  public var characterspacing: CGFloat {
    get { self._characterspacing }

    set {
      guard newValue >= 0.0 else { return }

      self._characterspacing = newValue
      self.updateFontMetaData(self._font)
    }
  }

  public var font: NSFont {
    get { self._font }

    set {
      if !newValue.fontDescriptor.symbolicTraits.contains(.monoSpace) {
        self.log.info("\(newValue) is not monospaced.")
      }

      let size = newValue.pointSize
      guard size >= NvimView.minFontSize, size <= NvimView.maxFontSize else { return }

      self._font = newValue
      self.updateFontMetaData(newValue)

      self.signalRemoteOptionChange(RemoteOption.fromFont(newValue))
    }
  }

  public var cwd: URL {
    get { self._cwd }

    set {
      self.api
        .setCurrentDir(dir: newValue.path)
        .subscribe(on: self.scheduler)
        .subscribe(onError: { [weak self] error in
          self?.eventsSubject
            .onError(Error.ipc(msg: "Could not set cwd to \(newValue)", cause: error))
        })
        .disposed(by: self.disposeBag)
    }
  }

  public var defaultCellAttributes: CellAttributes {
    self.cellAttributesCollection.defaultAttributes
  }

  override public var acceptsFirstResponder: Bool { true }

  public let scheduler: SerialDispatchQueueScheduler

  public internal(set) var currentPosition = Position.beginning

  public var events: Observable<Event> { self.eventsSubject.asObservable() }

  public init(frame _: NSRect, config: Config) {
    self.drawer = AttributesRunDrawer(
      baseFont: self._font,
      linespacing: self._linespacing,
      characterspacing: self._characterspacing,
      usesLigatures: self.usesLigatures
    )
    self.bridge = UiBridge(uuid: self.uuid, config: config)
    self.scheduler = SerialDispatchQueueScheduler(
      queue: self.queue,
      internalSerialQueueName: "com.qvacua.NvimView.NvimView"
    )

    self.sourceFileUrls = config.sourceFiles

    self.usesCustomTabBar = config.usesCustomTabBar
    if self.usesCustomTabBar { self.tabBar = TabBar<TabEntry>(withTheme: .default) }
    else { self.tabBar = nil }

    super.init(frame: .zero)

    self.api.streamResponses = true
    self.api.msgpackRawStream
      .subscribe(onNext: { [weak self] msg in
        switch msg {
        case let .notification(method, params):
          self?.log.debug("NOTIFICATION: \(method): \(params)")

          guard method == NvimView.rpcEventName else { return }
          self?.eventsSubject.onNext(.rpcEvent(params))

        case let .error(_, msg):
          self?.log.debug("MSG ERROR: \(msg)")

        case let .response(_, error, _):
          guard let array = error.arrayValue,
                array.count >= 2,
                array[0].uint64Value == RxNeovimApi.Error.exceptionRawValue,
                let errorMsg = array[1].stringValue else { return }

          // FIXME:
          if errorMsg.contains("Vim(tabclose):E784") {
            self?.eventsSubject.onNext(.warning(.cannotCloseLastTab))
          }
          if errorMsg.starts(with: "Vim(tabclose):E37") {
            self?.eventsSubject.onNext(.warning(.noWriteSinceLastChange))
          }
        }
      }, onError: {
        [weak self] error in self?.log.error(error)
      })
      .disposed(by: self.disposeBag)

    let db = self.disposeBag
    self.tabBar?.closeHandler = { [weak self] index, _, _ in
      self?.api
        .command(command: "tabclose \(index + 1)")
        .subscribe()
        .disposed(by: db)
    }
    self.tabBar?.selectHandler = { [weak self] _, tabEntry, _ in
      self?.api
        .setCurrentTabpage(tabpage: tabEntry.tabpage)
        .subscribe()
        .disposed(by: db)
    }
    self.tabBar?.reorderHandler = { [weak self] index, _, entries in
      // I don't know why, but `tabm ${last_index}` does not always work.
      let command = (index == entries.count - 1) ? "tabm" : "tabm \(index)"
      self?.api
        .command(command: command)
        .subscribe()
        .disposed(by: db)
    }

    self.bridge.consumer = self
    self.registerForDraggedTypes([NSPasteboard.PasteboardType(String(kUTTypeFileURL))])

    self.wantsLayer = true
    self.cellSize = FontUtils.cellSize(
      of: self.font, linespacing: self.linespacing, characterspacing: self.characterspacing
    )
  }

  override public convenience init(frame rect: NSRect) {
    self.init(
      frame: rect,
      config: Config(
        usesCustomTabBar: true,
        useInteractiveZsh: false,
        cwd: URL(fileURLWithPath: NSHomeDirectory()),
        nvimArgs: nil,
        envDict: nil,
        sourceFiles: []
      )
    )
  }

  @available(*, unavailable)
  public required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @IBAction public func debug1(_: Any?) {
    #if DEBUG
      do { try self.ugrid.dump() } catch { self.log.error("Could not dump UGrid: \(error)") }
    #endif
  }

  // MARK: - Internal

  let queue = DispatchQueue(
    label: String(reflecting: NvimView.self),
    qos: .userInteractive,
    target: .global(qos: .userInteractive)
  )

  let bridge: UiBridge

  let ugrid = UGrid()
  let cellAttributesCollection = CellAttributesCollection()
  let drawer: AttributesRunDrawer
  var baselineOffset = 0.cgf

  /// We store the last marked text because Cocoa's text input system does the following:
  /// 하 -> hanja popup -> insertText(하) -> attributedSubstring...() -> setMarkedText(下) -> ...
  /// We want to return "하" in attributedSubstring...()
  var lastMarkedText: String?

  var keyDownDone = true

  var lastClickedCellPosition = Position.null

  var offset = CGPoint.zero
  var cellSize = CGSize.zero

  var scrollGuardCounterX = 5
  var scrollGuardCounterY = 5

  var isCurrentlyPinching = false
  var pinchTargetScale = 1.cgf
  var pinchBitmap: NSBitmapImageRep?

  var currentlyResizing = false
  var currentEmoji = "😎"

  var _font = NvimView.defaultFont
  var _cwd = URL(fileURLWithPath: NSHomeDirectory())
  var isInitialResize = true

  // FIXME: Use self.tabEntries
  // cache the tabs for Touch Bar use
  var tabsCache = [NvimView.Tabpage]()

  let eventsSubject = PublishSubject<Event>()
  let disposeBag = DisposeBag()

  var markedText: String?
  var markedPosition = Position.null
  var markedSelectedRange: NSRange = .init(location: 0, length: 0)

  let bridgeLogger = OSLog(subsystem: Defs.loggerSubsystem, category: Defs.LoggerCategory.bridge)
  let log = OSLog(subsystem: Defs.loggerSubsystem, category: Defs.LoggerCategory.view)

  let sourceFileUrls: [URL]

  let rpcEventSubscriptionCondition = ConditionVariable()
  let nvimExitedCondition = ConditionVariable()

  var tabEntries = [TabEntry]()

  // MARK: - Private

  private var _linespacing = NvimView.defaultLinespacing
  private var _characterspacing = NvimView.defaultCharacterspacing
}

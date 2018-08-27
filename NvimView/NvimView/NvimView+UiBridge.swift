/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import RxNeovimApi
import RxSwift
import MessagePack

extension NvimView {

  func resize(_ value: MessagePackValue) {
    guard let array = MessagePackUtils.array(from: value, ofSize: 2, conversion: { $0.intValue }) else {
      return
    }

    self.bridgeLogger.debug("\(array[0]) x \(array[1])")
    gui.async {
      self.ugrid.resize(Size(width: array[0], height: array[1]))
      self.markForRenderWholeView()
    }
  }

  func clear() {
    self.bridgeLogger.mark()

    gui.async {
      self.grid.clear()
      self.markForRenderWholeView()
    }
  }

  func modeChange(_ value: MessagePackValue) {
    guard let mode = MessagePackUtils.value(from: value, conversion: { v -> CursorModeShape? in
      guard let rawValue = v.intValue else { return nil }
      return CursorModeShape(rawValue: UInt(rawValue))
    }) else { return }

    self.bridgeLogger.debug(name(of: mode))
    gui.async {
      self.mode = mode
    }
  }

  func scroll(_ value: MessagePackValue) {
//    self.bridgeLogger.debug(count)
//
//    gui.async {
//      self.grid.scroll(count)
//      self.markForRender(region: self.grid.region)
//      // Do not send msgs to agent -> neovim in the delegate method. It causes spinning
//      // when you're opening a file with existing swap file.
//      self.eventsSubject.onNext(.scroll)
//    }
  }

  func unmark(_ value: MessagePackValue) {
//    self.bridgeLogger.debug("\(row):\(column)")
//
//    gui.async {
//      let position = Position(row: row, column: column)
//
//      self.grid.unmarkCell(position)
//      self.markForRender(position: position)
//    }
  }

  func flush(_ renderData: [MessagePackValue]) {
    self.bridgeLogger.hr()

    gui.async {
      renderData.forEach { value in
        guard let renderEntry = value.arrayValue else { return }
        guard renderEntry.count == 2 else { return }

        guard let rawType = renderEntry[0].intValue,
              let innerArray = renderEntry[1].arrayValue,
              let type = RenderDataType(rawValue: rawType) else { return }

        switch type {

        case .rawLine:
          self.doRawLine(data: innerArray)

        case .goto:
          guard let row = innerArray[0].unsignedIntegerValue,
                let col = innerArray[1].unsignedIntegerValue else { return }

          self.doGoto(position: Position(row: Int(row), column: Int(col)))

        }
      }

      // The position stays at the first cell when we enter the terminal mode and the cursor seems to be drawn by
      // changing the background color of the corresponding cell...
      if self.mode != .termFocus {
        self.shouldDrawCursor = true
      }
    }
  }

  func setTitle(with value: MessagePackValue) {
    guard let title = value.stringValue else { return }

    self.bridgeLogger.debug(title)
    self.eventsSubject.onNext(.setTitle(title))
  }

  func stop() {
    self.bridgeLogger.hr()
    try? self.api
      .stop()
      .andThen(self.bridge.quit())
      .andThen(Completable.create { completable in
        self.eventsSubject.onNext(.neoVimStopped)
        self.eventsSubject.onCompleted()

        completable(.completed)
        return Disposables.create()
      })
      .observeOn(MainScheduler.instance)
      .wait()
  }

  func autoCommandEvent(_ value: MessagePackValue) {
    guard let array = MessagePackUtils.array(from: value, ofSize: 2, conversion: { $0.intValue }),
          let event = NvimAutoCommandEvent(rawValue: array[0]) else { return }
    let bufferHandle = array[1]

    self.bridgeLogger.debug("\(event) -> \(bufferHandle)")

    if event == .bufwinenter || event == .bufwinleave {
      self.bufferListChanged()
    }

    if event == .tabenter {
      self.eventsSubject.onNext(.tabChanged)
    }

    if event == .bufwritepost {
      self.bufferWritten(bufferHandle)
    }

    if event == .bufenter {
      self.newCurrentBuffer(bufferHandle)
    }
  }

  func ipcBecameInvalid(_ reason: String) {
    self.bridgeLogger.debug(reason)

    self.eventsSubject.onNext(.ipcBecameInvalid(reason))
    self.eventsSubject.onCompleted()

    self.bridgeLogger.error("Force-closing due to IPC error.")
    try? self.api
      .stop()
      .andThen(self.bridge.forceQuit())
      .observeOn(MainScheduler.instance)
      .wait()
  }

  private func doRawLine(data: [MessagePackValue]) {
    guard data.count == 7 else {
      self.stdoutLogger.error(
        "Data has wrong number of elements: \(data.count) instead of 7"
      )
      return
    }

    guard let row = data[0].intValue,
          let startCol = data[1].intValue,
          let endCol = data[2].intValue, // past last index, but can be 0
          let clearCol = data[3].intValue, // past last index (can be 0?)
          let clearAttr = data[4].intValue,
          let chunk = data[5].arrayValue?.compactMap({ $0.stringValue }),
          let attrIds = data[6].arrayValue?.compactMap({ $0.intValue })
      else {

      self.stdoutLogger.error("Values could not be read from: \(data)")
      return
    }

    self.bridgeLogger.trace(
      "row: \(row), startCol: \(startCol), endCol: \(endCol), " +
        "clearCol: \(clearCol), clearAttr: \(clearAttr), " +
        "chunk: \(chunk), attrIds: \(attrIds)"
    )

    let count = endCol - startCol
    guard chunk.count == count && attrIds.count == count else { return }
    self.ugrid.update(row: row,
                      startCol: startCol,
                      endCol: endCol,
                      clearCol: clearCol,
                      clearAttr: clearAttr,
                      chunk: chunk,
                      attrIds: attrIds)

    if self.usesLigatures {
      let leftBoundary = self.ugrid.leftBoundaryOfWord(
        at: Position(row: row, column: startCol)
      )
      let rightBoundary = self.ugrid.rightBoundaryOfWord(
        at: Position(row: row, column: max(0, endCol - 1))
      )
      self.markForRender(region: Region(
        top: row, bottom: row, left: leftBoundary, right: rightBoundary
      ))
    } else {
      self.markForRender(region: Region(
        top: row, bottom: row, left: startCol, right: max(0, endCol - 1)
      ))
    }

    if clearCol > endCol {
      self.markForRender(region: Region(
        top: row, bottom: row, left: endCol, right: max(endCol, clearCol - 1)
      ))
    }
  }

  private func doGoto(position: Position) {
//    self.bridgeLogger.debug(position)

    self.markForRender(cellPosition: self.grid.position)
    self.grid.goto(position)
  }
}

// MARK: - Simple
extension NvimView {

  func bell() {
    self.bridgeLogger.mark()

    NSSound.beep()
  }

  func cwdChanged(_ value: MessagePackValue) {
    guard let cwd = value.stringValue else { return }

    self.bridgeLogger.debug(cwd)
    self._cwd = URL(fileURLWithPath: cwd)
    self.eventsSubject.onNext(.cwdChanged)
  }

  func colorSchemeChanged(_ value: MessagePackValue) {
    guard let values = MessagePackUtils.array(from: value, ofSize: 5, conversion: { $0.intValue }) else { return }

    let theme = Theme(values)
    self.bridgeLogger.debug(theme)

    gui.async {
      self.theme = theme
      self.eventsSubject.onNext(.colorschemeChanged(theme))
    }
  }

  func defaultColorsChanged(_ value: MessagePackValue) {
    guard let values = MessagePackUtils.array(
      from: value, ofSize: 3, conversion: { $0.intValue }
    ) else {
      return
    }

    self.bridgeLogger.trace(values)

    let attrs = CellAttributes(
      fontTrait: [],
      foreground: values[0],
      background: values[1],
      special: values[2],
      reverse: false
    )
    gui.async {
      self.ugrid.set(attrs: attrs, for: 0)
      self.layer?.backgroundColor = ColorUtils.cgColorIgnoringAlpha(
        attrs.background
      )
    }
  }

  func setDirty(with value: MessagePackValue) {
    guard let dirty = value.boolValue else { return }

    self.bridgeLogger.debug(dirty)
    self.eventsSubject.onNext(.setDirtyStatus(dirty))
  }

  func setAttr(with value: MessagePackValue) {
    guard let array = value.arrayValue else { return }
    guard array.count == 6 else { return }

    guard let id = array[0].intValue,
          let rawTrait = array[1].unsignedIntegerValue,
          let fg = array[2].intValue,
          let bg = array[3].intValue,
          let sp = array[4].intValue,
          let reverse = array[5].boolValue
      else {

      self.bridgeLogger.error("Could not get highlight attributes from " +
                                "\(value)")
      return
    }
    let trait = FontTrait(rawValue: UInt(rawTrait))

    let attrs = CellAttributes(
      fontTrait: trait,
      foreground: fg,
      background: bg,
      special: sp,
      reverse: reverse
    )

    self.bridgeLogger.trace("\(id) -> \(attrs)")

    gui.async {
      self.ugrid.set(attrs: attrs, for: id)
    }
  }

  func updateMenu() {
    self.bridgeLogger.mark()
  }

  func busyStart() {
    self.bridgeLogger.mark()
  }

  func busyStop() {
    self.bridgeLogger.mark()
  }

  func mouseOn() {
    self.bridgeLogger.mark()
  }

  func mouseOff() {
    self.bridgeLogger.mark()
  }

  func visualBell() {
    self.bridgeLogger.mark()
  }

  func suspend() {
    self.bridgeLogger.mark()
  }
}

extension NvimView {

  func markForRender(cellPosition position: Position) {
    self.markForRender(position: position)

    if self.grid.isCellEmpty(position) {
      self.markForRender(position: self.grid.previousCellPosition(position))
    }

    if self.grid.isNextCellEmpty(position) {
      self.markForRender(position: self.grid.nextCellPosition(position))
    }
  }

  func markForRender(position: Position) {
    self.markForRender(row: position.row, column: position.column)
  }

  func markForRender(screenCursor position: Position) {
    self.markForRender(position: position)
    if self.grid.isNextCellEmpty(position) {
      self.markForRender(position: self.grid.nextCellPosition(position))
    }
  }

  func markForRenderWholeView() {
    self.needsDisplay = true
  }

  func markForRender(region: Region) {
    self.setNeedsDisplay(self.rect(for: region))
  }

  func markForRender(row: Int, column: Int) {
    self.setNeedsDisplay(self.rect(forRow: row, column: column))
  }
}

extension NvimView {

  private func bufferWritten(_ handle: Int) {
    self
      .currentBuffer()
      .flatMap { curBuf -> Single<NvimView.Buffer> in
        self.neoVimBuffer(for: Api.Buffer(handle), currentBuffer: curBuf.apiBuffer)
      }
      .subscribe(onSuccess: {
        self.eventsSubject.onNext(.bufferWritten($0))
        if #available(OSX 10.12.2, *) {
          self.updateTouchBarTab()
        }
      }, onError: { error in
        self.eventsSubject.onNext(.apiError(msg: "Could not get the buffer \(handle).", cause: error))
      })
  }

  private func newCurrentBuffer(_ handle: Int) {
    self
      .currentBuffer()
      .filter { $0.apiBuffer.handle == handle }
      .subscribe(onSuccess: {
        self.eventsSubject.onNext(.newCurrentBuffer($0))
        if #available(OSX 10.12.2, *) {
          self.updateTouchBarTab()
        }
      }, onError: { error in
        self.eventsSubject.onNext(.apiError(msg: "Could not get the current buffer.", cause: error))
      })
  }

  private func bufferListChanged() {
    self.eventsSubject.onNext(.bufferListChanged)
    if #available(OSX 10.12.2, *) {
      self.updateTouchBarCurrentBuffer()
    }
  }
}

private let gui = DispatchQueue.main

private func name(of mode: CursorModeShape) -> String {
  switch mode {
    // @formatter:off
    case .normal:                  return "Normal"
    case .visual:                  return "Visual"
    case .insert:                  return "Insert"
    case .replace:                 return "Replace"
    case .cmdline:                 return "Cmdline"
    case .cmdlineInsert:           return "CmdlineInsert"
    case .cmdlineReplace:          return "CmdlineReplace"
    case .operatorPending:         return "OperatorPending"
    case .visualExclusive:         return "VisualExclusive"
    case .onCmdline:               return "OnCmdline"
    case .onStatusLine:            return "OnStatusLine"
    case .draggingStatusLine:      return "DraggingStatusLine"
    case .onVerticalSepLine:       return "OnVerticalSepLine"
    case .draggingVerticalSepLine: return "DraggingVerticalSepLine"
    case .more:                    return "More"
    case .moreLastLine:            return "MoreLastLine"
    case .showingMatchingParen:    return "ShowingMatchingParen"
    case .termFocus:               return "TermFocus"
    case .count:                   return "Count"
    // @formatter:on
  }
}

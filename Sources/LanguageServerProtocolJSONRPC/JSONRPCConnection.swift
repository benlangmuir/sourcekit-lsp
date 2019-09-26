//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SKSupport
import LanguageServerProtocol
import Dispatch
import Foundation
import NIO
import NIOExtras
import NIOFoundationCompat

struct OutstandingRequest {
  var promise: EventLoopPromise<LSPResult<Any>>
  var responseType: ResponseType.Type
}

final class JSONRPCConnectionBridge {

  let messageHandler: (JSONRPCMessage) -> Void
  let errorHandler: (Error) -> Void
  let handlerQueue: DispatchQueue
  var scratchBuffer: ByteBuffer! = nil
  let jsonEncoder: JSONEncoder = JSONEncoder()
  let jsonDecoder: JSONDecoder
  var outstandingRequests: [RequestID: OutstandingRequest] = [:]

  init(
    `protocol` messageRegistry: MessageRegistry,
    messageHandler: @escaping (JSONRPCMessage) -> Void,
    errorHandler: @escaping (Error) -> Void,
    handlerQueue: DispatchQueue)
  {
    self.messageHandler = messageHandler
    self.errorHandler = errorHandler
    self.handlerQueue = handlerQueue
    self.jsonDecoder = JSONDecoder()
    jsonDecoder.userInfo[.messageRegistryKey] = messageRegistry
  }
}

extension JSONRPCConnectionBridge: ChannelDuplexHandler {

  typealias InboundIn = ByteBuffer
  typealias InbountOut = JSONRPCMessage
  typealias OutboundIn = (JSONRPCMessage, OutstandingRequest?)
  typealias OutboundOut = ByteBuffer

  func handlerAdded(context: ChannelHandlerContext) {
    self.scratchBuffer = context.channel.allocator.buffer(capacity: 512)
    self.jsonDecoder.userInfo[.responseTypeCallbackKey] = { id in
      context.eventLoop.preconditionInEventLoop()
      guard let outstanding = self.outstandingRequests[id] else {
        log("Unknown request for \(id)", level: .error)
        return nil
      }
      return outstanding.responseType
    } as JSONRPCMessage.ResponseTypeCallback
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var bytes = unwrapInboundIn(data)
    let data = bytes.readData(length: bytes.readableBytes)!
    do {
      let message = try jsonDecoder.decode(JSONRPCMessage.self, from: data)
      let result: LSPResult<Any>
      let requestID: RequestID

      switch message {
        case .errorResponse(let error, id: let id):
          result = .failure(error)
          requestID = id
        case .response(let value, id: let id):
          result = .success(value)
          requestID = id
        default:
          handlerQueue.async {
            self.messageHandler(message)
          }
          return
      }

      guard let outstanding = outstandingRequests.removeValue(forKey: requestID) else {
        log("Unknown request for \(requestID)", level: .error)
        return
      }

      outstanding.promise.succeed(result)

    } catch {
      self.errorCaught(context: context, error: error)   
    }
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let (message, replyInfo) = self.unwrapOutboundIn(data)
    if case .request(_, let id) = message {
      precondition(outstandingRequests[id] == nil)
      outstandingRequests[id] = replyInfo!
    }
    writeImpl(context: context, message: message, promise: promise)
  }

  func writeImpl(context: ChannelHandlerContext, message: JSONRPCMessage, promise: EventLoopPromise<Void>?) {
    do {
      let data = try jsonEncoder.encode(message)
      scratchBuffer.reserveCapacity(data.count)
      scratchBuffer.clear()
      scratchBuffer.writeBytes(data)
      context.write(self.wrapOutboundOut(scratchBuffer), promise: promise)
    } catch {
      // If anything goes wrong, tell the `Channel` and fail the write promise.
      context.fireErrorCaught(error)
      promise?.fail(error)
    }
  }

  // FIXME: when can this happen?
  func channelInactive(context: ChannelHandlerContext) {
    outstandingRequests.forEach { _, outstanding in
      outstanding.promise.succeed(.failure(.cancelled))
    }
    outstandingRequests.removeAll()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    if let error = error as? MessageDecodingError {
      // FIXME: for errors like parseError, or invalidRequest should we just give up?
      switch (error.messageKind, error.id) {
        case (.request, let id?):
          // Send failure as response to client.
          writeImpl(
            context: context,
            message: .errorResponse(ResponseError(error), id: id),
            promise: nil)
          context.flush()
          return
        case (.response, let id?):
          if let replyInfo = outstandingRequests.removeValue(forKey: id) {
            // Send failure as response to outstanding request.
            replyInfo.promise.succeed(.failure(ResponseError(error)))
          } else {
            log("error in response to unknown request \(id) \(error)", level: .error)
          }
          return
        case (.notification, _):
          if error.code == .methodNotFound {
            log("ignoring unknown notification \(error)")
            return
          }
        default:
          break
      }
    }

    // Fatal error: report and then close the connection.
    handlerQueue.async {
      self.errorHandler(error)
    }
    context.close(promise: nil)
  }
}

/// A connection between a message handler (e.g. language server) in the same process as the connection object and a remote message handler (e.g. language client) that may run in another process using JSON RPC messages sent over a pair of in/out file descriptors.
///
/// For example, inside a language server, the `JSONRPCConnection` takes the language service implemenation as its `receiveHandler` and itself provides the client connection for sending notifications and callbacks.
public final class JSONRPCConection {

  let group: EventLoopGroup
  var channel: Channel? = nil
  let inFD: CInt
  let outFD: CInt

  var receiveHandler: MessageHandler? = nil
  let queue: DispatchQueue = DispatchQueue(label: "jsonrpc-queue", qos: .userInitiated)
  let messageRegistry: MessageRegistry

  /// *For Testing* Whether to wait for requests to finish before handling the next message.
  let syncRequests: Bool

  enum State {
    case created, running, closed
  }

  /// Current state of the connection, used to ensure correct usage.
  var state: State

  private var _nextRequestID: Int = 0
  var closeHandler: () -> Void

  public init(
    protocol messageRegistry: MessageRegistry,
    inFD: Int32,
    outFD: Int32,
    syncRequests: Bool = false,
    closeHandler: @escaping () -> Void = {})
  {
    state = .created
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.inFD = inFD
    self.outFD = outFD
    self.closeHandler = closeHandler
    self.messageRegistry = messageRegistry
    self.syncRequests = syncRequests
  }

  deinit {
    assert(state == .closed)
  }

  /// Start processing `inFD` and send messages to `receiveHandler`.
  ///
  /// - parameter receiveHandler: The message handler to invoke for requests received on the `inFD`.
  public func start(receiveHandler: MessageHandler) {
    precondition(state == .created)
    state = .running
    self.receiveHandler = receiveHandler

    // FIXME: error handling?
    self.channel = try! PipeBootstrap(group: group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
      .channelInitializer { channel in
        channel.pipeline.addHandlers([
          ByteToMessageHandler(NIOJSONRPCFraming.ContentLengthHeaderFrameDecoder()),
          NIOJSONRPCFraming.ContentLengthHeaderFrameEncoder(),
          // DebugInboundEventsHandler { event, context in
          //   let message: String
          //   switch event {
          //   case .registered:
          //       message = "Channel registered"
          //   case .unregistered:
          //       message = "Channel unregistered"
          //   case .active:
          //       message = "Channel became active"
          //   case .inactive:
          //       message = "Channel became inactive"
          //   case .read(let data):
          //       message = "Channel read \(data)"
          //   case .readComplete:
          //       message = "Channel completed reading"
          //   case .writabilityChanged(let isWritable):
          //       message = "Channel writability changed to \(isWritable)"
          //   case .userInboundEventTriggered(let event):
          //       message = "Channel user inbound event \(event) triggered"
          //   case .errorCaught(let error):
          //       message = "Channel caught error: \(error)"
          //   }
          //   log(message + " in \(context.name)", level: .error)
          // },
          JSONRPCConnectionBridge(
            protocol: self.messageRegistry,
            messageHandler: self.handle(_:),
            errorHandler: { error in log("IO error \(type(of: error))", level: .error) },
            handlerQueue: self.queue),
        ])
      }
      .withPipes(inputDescriptor: inFD, outputDescriptor: outFD).wait()
  }

  /// Whether we can send messages in the current state.
  ///
  /// - parameter shouldLog: Whether to log an info message if not ready.
  func readyToSend(shouldLog: Bool = true) -> Bool {
    precondition(state != .created, "tried to send message before calling start(messageHandler:)")
    let ready = state == .running
    if shouldLog && !ready {
      log("ignoring message; state = \(state)")
    }
    return ready
  }

  /// Handle a single message by dispatching it to `receiveHandler`.
  func handle(_ message: JSONRPCMessage) {
    switch message {
    case .notification(let notification):
      notification._handle(receiveHandler!, connection: self)
    case .request(let request, id: let id):
      request._handle(receiveHandler!, id: id, connection: self, sync: syncRequests)
    case .response, .errorResponse:
      fatalError("handled by \(JSONRPCConnectionBridge.self)")
    }
  }

  func send(message: JSONRPCMessage, replyInfo: OutstandingRequest? = nil) {
    guard readyToSend(), let channel = self.channel else { return }

    channel.writeAndFlush((message, replyInfo)).whenFailure { error in
      switch error {
        case ChannelError.ioOnClosedChannel:
          // FIXME: is this the right way to handle it?
          replyInfo?.promise.succeed(.failure(ResponseError.cancelled))
        default:
          replyInfo?.promise.succeed(.failure(ResponseError.unknown("\(error)")))
      }
    }
  }

  /// Close the connection.
  public func close() {
    queue.sync { _close() }
  }

  /// Close the connection. *Must be called on `queue`.*
  func _close() {
    guard state == .running else { return }

    log("\(JSONRPCConection.self): closing...")
    state = .closed
    do {
      try self.channel?.close().wait()
    } catch ChannelError.alreadyClosed {
      // Okay.
    } catch {
      // FIXME: log and ignore?
      fatalError("could not close channel: \(error)")
    }
    receiveHandler = nil // break retain cycle
    closeHandler()
  }

  /// Request id for the next outgoing request.
  func nextRequestID() -> RequestID {
    _nextRequestID += 1
    return .number(_nextRequestID)
  }
}

extension JSONRPCConection: _IndirectConnection {
  // MARK: Connection interface

  public func send<Notification: NotificationType>(_ notification: Notification) {
    guard readyToSend() else { return }
    send(message: .notification(notification))
  }

  public func send<Request: RequestType>(
    _ request: Request,
    queue: DispatchQueue,
    reply: @escaping (LSPResult<Request.Response>) -> Void
  ) -> RequestID {

    let id: RequestID = self.queue.sync { nextRequestID() }

    guard let channel = self.channel else {
      queue.async {
        reply(.failure(.cancelled))
      }
      return id
    }

    let promise = channel.eventLoop.makePromise(of: LSPResult<Any>.self)
    promise.futureResult
      .recover { error in
        // FIXME: error handling?
        fatalError("error \(error)")
      }
      .whenSuccess { anyResult in
        queue.async {
          reply(anyResult.map { $0 as! Request.Response })
        }
      }

    self.send(message: .request(request, id: id), replyInfo: OutstandingRequest(promise: promise, responseType: Request.Response.self))
    return id
  }

  public func sendReply<Response>(_ response: LSPResult<Response>, id: RequestID) where Response: ResponseType {
    guard readyToSend() else { return }
    switch response {
      case .success(let result):
        self.send(message: .response(result, id: id))
      case .failure(let error):
        self.send(message: .errorResponse(error, id: id))
    }
  }
}

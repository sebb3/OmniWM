import CoreGraphics
import Darwin
import Foundation

struct DockWorkspaceTransitionMember: Sendable {
  let windowId: UInt32
  let from: CGAffineTransform
  let to: CGAffineTransform

  init(windowId: UInt32, from: CGAffineTransform, to: CGAffineTransform) {
    self.windowId = windowId
    self.from = from
    self.to = to
  }
}

enum DockPayloadClient {
  static func runWorkspaceTransition(
    members: [DockWorkspaceTransitionMember],
    duration: Duration,
    frameInterval: Duration
  ) async -> Bool {
    guard let durationNS = duration.nanoseconds,
      let intervalNS = frameInterval.nanoseconds
    else { return false }
    let operation = Task.detached(priority: nil) {
      guard !Task.isCancelled,
        let transport = DockPayloadSocketTransport.connectDefault()
      else {
        Log.layout.error("Dock workspace transition could not connect")
        return false
      }
      return await withTaskCancellationHandler {
        DockPayloadSession(transport: transport).runTransition(
          members: members,
          durationNS: durationNS,
          frameIntervalNS: intervalNS
        )
      } onCancel: {
        transport.close()
      }
    }
    return await withTaskCancellationHandler {
      await operation.value
    } onCancel: {
      operation.cancel()
    }
  }
}

extension Duration {
  fileprivate var nanoseconds: UInt64? {
    let components = self.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return nil }
    let (seconds, overflow1) = UInt64(components.seconds).multipliedReportingOverflow(
      by: 1_000_000_000)
    let fractional = UInt64(components.attoseconds) / 1_000_000_000
    let (result, overflow2) = seconds.addingReportingOverflow(fractional)
    return overflow1 || overflow2 ? nil : result
  }
}

protocol DockPayloadTransport: AnyObject, Sendable {
  func writeAll(_ data: Data) -> Bool
  func readExactly(_ count: Int) -> Data?
  func close()
}

final class DockPayloadSocketTransport: DockPayloadTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) { self.descriptor = descriptor }

  static func connectDefault() -> DockPayloadSocketTransport? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let transport = DockPayloadSocketTransport(descriptor: fd)
    var noSigPipe: Int32 = 1
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
    _ = setsockopt(
      fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    _ = setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    let path = "/tmp/hs2-dock-window-v2-\(NSUserName()).socket"
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      transport.close()
      return nil
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.initializeMemory(as: UInt8.self, repeating: 0)
      _ = path.utf8CString.withUnsafeBytes { source in
        source.copyBytes(to: destination)
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
    }
    guard result == 0 else {
      transport.close()
      return nil
    }
    return transport
  }

  func writeAll(_ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0 else { return false }
        let result = Darwin.send(
          fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_NOSIGNAL)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { return false }
        offset += result
      }
      return true
    }
  }

  func readExactly(_ count: Int) -> Data? {
    var data = Data(count: count)
    let succeeded = data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0 else { return false }
        let result = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { return false }
        offset += result
      }
      return true
    }
    return succeeded ? data : nil
  }

  func close() {
    lock.lock()
    let fd = descriptor
    descriptor = -1
    lock.unlock()
    if fd >= 0 {
      _ = Darwin.shutdown(fd, SHUT_RDWR)
      _ = Darwin.close(fd)
    }
  }

  deinit { close() }
}

struct DockPayloadSession {
  let transport: DockPayloadTransport

  private func fail(_ stage: String) -> Bool {
    Log.layout.error("Dock workspace transition failed at \(stage)")
    return false
  }

  func runTransition(
    members: [DockWorkspaceTransitionMember], durationNS: UInt64, frameIntervalNS: UInt64,
    nonce: Data = DockPayloadProtocol.randomNonce()
  ) -> Bool {
    defer { transport.close() }
    guard
      DockPayloadProtocol.validate(
        members: members, durationNS: durationNS, frameIntervalNS: frameIntervalNS)
    else { return fail("validation") }
    guard nonce.count == 16 else { return fail("nonce") }
    var requestID: UInt64 = 1
    guard
      send(
        type: .handshakeRequest, requestID: requestID, sessionID: 0,
        payload: DockPayloadProtocol.handshakeRequest(nonce: nonce)),
      let handshake = receive(expectedType: .handshakeResponse, requestID: requestID),
      let negotiated = DockPayloadProtocol.decodeHandshake(handshake.payload),
      handshake.envelope.sessionID == negotiated.sessionID,
      negotiated.valid(nonce: nonce)
    else { return fail("handshake") }
    let sessionID = negotiated.sessionID
    var leases: [(UInt64, UInt64)] = []
    defer {
      for (lease, window) in leases.reversed() {
        requestID &+= 1
        _ = send(
          type: .leaseRelease, requestID: requestID, sessionID: sessionID,
          payload: DockPayloadProtocol.leasePayload(nonce: nonce, leaseID: lease, windowID: window))
        _ = receive(expectedType: .response, requestID: requestID, sessionID: sessionID)
      }
      requestID &+= 1
      _ = send(
        type: .leaseClear, requestID: requestID, sessionID: sessionID,
        payload: DockPayloadProtocol.leasePayload(nonce: nonce, leaseID: 1, windowID: 1))
      _ = receive(expectedType: .response, requestID: requestID, sessionID: sessionID)
    }
    for (index, member) in members.enumerated() {
      requestID &+= 1
      let leaseID = UInt64(index + 1)
      let windowID = UInt64(member.windowId)
      guard
        send(
          type: .leaseCreate, requestID: requestID, sessionID: sessionID,
          payload: DockPayloadProtocol.leasePayload(
            nonce: nonce, leaseID: leaseID, windowID: windowID)),
        let response = receive(expectedType: .response, requestID: requestID, sessionID: sessionID),
        let status = DockPayloadProtocol.decodeResponse(response.payload),
        status.0 == 0, status.1 == leaseID
      else { return fail("lease \(index)") }
      leases.append((leaseID, windowID))
    }
    requestID &+= 1
    guard let payload = DockPayloadProtocol.transitionRequest(
      nonce: nonce, leases: leases, members: members,
      durationNS: durationNS, frameIntervalNS: frameIntervalNS)
    else { return fail("transition encoding") }
    guard send(type: .transitionRequest, requestID: requestID, sessionID: sessionID, payload: payload)
    else { return fail("transition send") }
    guard let response = receive(
      expectedType: .response, requestID: requestID, sessionID: sessionID)
    else { return fail("transition receive") }
    guard let status = DockPayloadProtocol.decodeResponse(response.payload) else {
      return fail("transition response decoding")
    }
    guard status.0 == 0 else {
      return fail(
        "transition server status \(status.0) detail \(response.payload.u16(2) ?? 0) value \(status.1)")
    }
    guard status.1 == UInt64(members.count) else {
      return fail("transition member count \(status.1)")
    }
    return true
  }

  private func send(
    type: DockPayloadProtocol.MessageType, requestID: UInt64, sessionID: UInt64, payload: Data
  ) -> Bool {
    guard
      let envelope = DockPayloadProtocol.envelope(
        type: type, payloadBytes: payload.count,
        requestID: requestID, sessionID: sessionID)
    else { return false }
    return transport.writeAll(envelope + payload)
  }

  private func receive(
    expectedType: DockPayloadProtocol.MessageType, requestID: UInt64, sessionID: UInt64? = nil
  )
    -> (envelope: DockPayloadProtocol.Envelope, payload: Data)?
  {
    guard let header = transport.readExactly(DockPayloadProtocol.envelopeBytes),
      let envelope = DockPayloadProtocol.decodeEnvelope(header),
      envelope.type == expectedType.rawValue,
      envelope.requestID == requestID, sessionID.map({ $0 == envelope.sessionID }) ?? true,
      let payload = transport.readExactly(Int(envelope.payloadBytes))
    else { return nil }
    return (envelope, payload)
  }
}

enum DockPayloadProtocol {
  static let envelopeBytes = 40
  static let maximumPayloadBytes = 3_620
  static let requiredCapabilities: UInt64 = (1 << 5) | (1 << 6)
  static let valueLimit = 1_000_000.0

  enum MessageType: UInt16 {
    case handshakeRequest = 1, handshakeResponse = 2, leaseCreate = 3, leaseRelease = 4,
      leaseClear = 5, response = 11, transitionRequest = 13
  }
  struct Envelope {
    let type: UInt16
    let payloadBytes: UInt16
    let requestID: UInt64
    let sessionID: UInt64
  }
  struct Handshake {
    let major: UInt16
    let minor: UInt16
    let build: UInt32
    let available: UInt64
    let granted: UInt64
    let sessionID: UInt64
    let error: UInt16
    let nonce: Data
    func valid(nonce expected: Data) -> Bool {
      major == 2 && minor == 0 && build == 2 && sessionID != 0 && error == 0 && nonce == expected
        && available & Self.required == Self.required && granted & Self.required == Self.required
    }
    private static let required = DockPayloadProtocol.requiredCapabilities
  }

  static func randomNonce() -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    arc4random_buf(&bytes, bytes.count)
    return Data(bytes)
  }
  static func validate(
    members: [DockWorkspaceTransitionMember], durationNS: UInt64, frameIntervalNS: UInt64
  ) -> Bool {
    let windowIds = Set(members.map(\.windowId))
    return !members.isEmpty && members.count <= 32 && windowIds.count == members.count
      && durationNS > 0 && durationNS <= 2_000_000_000 && frameIntervalNS >= 1_000_000
      && frameIntervalNS <= durationNS
      && members.allSatisfy { $0.windowId != 0 && finite($0.from) && finite($0.to) }
  }
  private static func finite(_ t: CGAffineTransform) -> Bool {
    [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy { $0.isFinite && abs($0) <= valueLimit }
  }

  static func envelope(type: MessageType, payloadBytes: Int, requestID: UInt64, sessionID: UInt64)
    -> Data?
  {
    guard payloadBytes <= maximumPayloadBytes, requestID != 0 else { return nil }
    var d = Data()
    d.put(UInt32(0x4432_5348))
    d.put(UInt16(2))
    d.put(UInt16(0))
    d.put(type.rawValue)
    d.put(UInt16(0))
    d.put(UInt16(40))
    d.put(UInt16(payloadBytes))
    d.put(requestID)
    d.put(sessionID)
    d.put(UInt64(0))
    return d
  }
  static func decodeEnvelope(_ d: Data) -> Envelope? {
    guard d.count == 40, d.u32(0) == 0x4432_5348, d.u16(4) == 2, d.u16(6) == 0, d.u16(10) == 0,
      d.u16(12) == 40, d.u64(32) == 0, let type = d.u16(8), MessageType(rawValue: type) != nil,
      let size = d.u16(14), Int(size) <= maximumPayloadBytes, let request = d.u64(16), request != 0,
      let session = d.u64(24)
    else { return nil }
    return Envelope(type: type, payloadBytes: size, requestID: request, sessionID: session)
  }
  static func handshakeRequest(nonce: Data) -> Data {
    var d = Data()
    d.put(UInt16(2))
    d.put(UInt16(2))
    d.put(UInt32(2))
    d.put(UInt32(2))
    d.put(requiredCapabilities)
    d.put(UInt64(0))
    d.append(nonce)
    return d
  }
  static func decodeHandshake(_ d: Data) -> Handshake? {
    guard d.count == 64, d.u32(60) == 0, let major = d.u16(0), let minor = d.u16(2),
      let build = d.u32(4), let available = d.u64(8), let granted = d.u64(16),
      let session = d.u64(24), let error = d.u16(40)
    else { return nil }
    return Handshake(
      major: major, minor: minor, build: build, available: available, granted: granted,
      sessionID: session, error: error, nonce: d.subdata(in: 44..<60))
  }
  static func leasePayload(nonce: Data, leaseID: UInt64, windowID: UInt64) -> Data {
    var d = nonce
    d.put(leaseID)
    d.put(windowID)
    d.put(UInt16(1 << 6))
    return d
  }
  static func transitionRequest(
    nonce: Data, leases: [(UInt64, UInt64)], members: [DockWorkspaceTransitionMember],
    durationNS: UInt64, frameIntervalNS: UInt64
  ) -> Data? {
    guard leases.count == members.count,
      validate(members: members, durationNS: durationNS, frameIntervalNS: frameIntervalNS)
    else { return nil }
    var d = nonce
    d.put(durationNS)
    d.put(frameIntervalNS)
    d.put(UInt16(members.count))
    d.put(UInt16(0))
    for (i, m) in members.enumerated() {
      d.put(leases[i].0)
      d.put(UInt64(m.windowId))
      for v in [
        m.from.a, m.from.b, m.from.c, m.from.d, m.from.tx, m.from.ty, m.to.a, m.to.b, m.to.c,
        m.to.d, m.to.tx, m.to.ty,
      ] { d.put(v.bitPattern) }
    }
    return d
  }
  static func decodeResponse(_ d: Data) -> (UInt16, UInt64)? {
    guard d.count == 12, let error = d.u16(0), d.u16(2) == 0, let value = d.u64(4) else {
      return nil
    }
    return (error, value)
  }
}

extension Data {
  fileprivate mutating func put<T: FixedWidthInteger>(_ value: T) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
  }
  fileprivate func u16(_ o: Int) -> UInt16? { get(o) }
  fileprivate func u32(_ o: Int) -> UInt32? { get(o) }
  fileprivate func u64(_ o: Int) -> UInt64? { get(o) }
  private func get<T: FixedWidthInteger>(_ o: Int) -> T? {
    guard o >= 0, o + MemoryLayout<T>.size <= count else { return nil }
    return subdata(in: o..<o + MemoryLayout<T>.size).withUnsafeBytes {
      T(littleEndian: $0.loadUnaligned(as: T.self))
    }
  }
}

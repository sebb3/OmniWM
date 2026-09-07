import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite struct DockPayloadClientTests {
  @Test func transitionGoldenGeometry() throws {
    let member = DockWorkspaceTransitionMember(
      windowId: 42,
      from: CGAffineTransform(a: 1, b: 2, c: 3, d: 4, tx: 5, ty: 6),
      to: CGAffineTransform(a: 7, b: 8, c: 9, d: 10, tx: 11, ty: 12)
    )
    let nonce = Data(0..<16)
    let payload = try #require(
      DockPayloadProtocol.transitionRequest(
        nonce: nonce, leases: [(9, 42)], members: [member], durationNS: 2_000_000,
        frameIntervalNS: 1_000_000
      ))
    #expect(payload.count == 148)
    #expect(payload.prefix(16) == nonce)
    #expect(payload.u64ForTest(16) == 2_000_000)
    #expect(payload.u64ForTest(24) == 1_000_000)
    #expect(payload.u16ForTest(32) == 1)
    #expect(payload.u16ForTest(34) == 0)
    #expect(payload.u64ForTest(36) == 9)
    #expect(payload.u64ForTest(44) == 42)
    #expect(Double(bitPattern: try #require(payload.u64ForTest(52))) == 1)
    #expect(Double(bitPattern: try #require(payload.u64ForTest(140))) == 12)
  }

  @Test func envelopeGoldenAndStrictDecode() throws {
    let data = try #require(
      DockPayloadProtocol.envelope(
        type: .transitionRequest, payloadBytes: 148, requestID: 7, sessionID: 8))
    #expect(data.count == 40)
    #expect(
      Array(data.prefix(16)) == [0x48, 0x53, 0x32, 0x44, 2, 0, 0, 0, 13, 0, 0, 0, 40, 0, 148, 0])
    let decoded = try #require(DockPayloadProtocol.decodeEnvelope(data))
    #expect(decoded.requestID == 7)
    #expect(decoded.sessionID == 8)
    var corrupt = data
    corrupt[10] = 1
    #expect(DockPayloadProtocol.decodeEnvelope(corrupt) == nil)
  }

  @Test func boundsAndFiniteValidation() {
    let valid = DockWorkspaceTransitionMember(windowId: 1, from: .identity, to: .identity)
    #expect(
      DockPayloadProtocol.validate(
        members: [valid], durationNS: 1_000_000, frameIntervalNS: 1_000_000))
    #expect(!DockPayloadProtocol.validate(members: [], durationNS: 1, frameIntervalNS: 1_000_000))
    #expect(
      !DockPayloadProtocol.validate(
        members: Array(repeating: valid, count: 33), durationNS: 1, frameIntervalNS: 1_000_000))
    let bad = DockWorkspaceTransitionMember(
      windowId: 1, from: CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
      to: .identity)
    #expect(
      !DockPayloadProtocol.validate(
        members: [bad], durationNS: 1_000_000, frameIntervalNS: 1_000_000))
  }

  @Test func capabilityAndNonceValidation() throws {
    let nonce = Data(repeating: 5, count: 16)
    var payload = handshakePayload(
      nonce: nonce, capabilities: DockPayloadProtocol.requiredCapabilities)
    let valid = try #require(DockPayloadProtocol.decodeHandshake(payload))
    #expect(valid.valid(nonce: nonce))
    payload.replaceSubrange(16..<24, with: withLE(UInt64(1 << 5)))
    let missing = try #require(DockPayloadProtocol.decodeHandshake(payload))
    #expect(!missing.valid(nonce: nonce))
    #expect(!valid.valid(nonce: Data(repeating: 6, count: 16)))
  }

  @Test func sessionUsesExactFramingAndRejectsMismatchedResponse() {
    let transport = ScriptedTransport()
    let nonce = Data(repeating: 1, count: 16)
    transport.responses = [
      frame(
        .handshakeResponse, request: 99, session: 77,
        payload: handshakePayload(
          nonce: nonce, capabilities: DockPayloadProtocol.requiredCapabilities))
    ]
    let member = DockWorkspaceTransitionMember(windowId: 1, from: .identity, to: .identity)
    #expect(
      !DockPayloadSession(transport: transport).runTransition(
        members: [member], durationNS: 1_000_000, frameIntervalNS: 1_000_000,
        nonce: nonce))
    #expect(transport.readRequests.first == 40)
    #expect(transport.closed)
  }

  @Test func sessionNegotiatesLeasesRunsOneTransitionAndCleansUp() {
    let transport = ScriptedTransport()
    let nonce = Data(repeating: 7, count: 16)
    transport.responses = [
      frame(
        .handshakeResponse, request: 1, session: 77,
        payload: handshakePayload(
          nonce: nonce, capabilities: DockPayloadProtocol.requiredCapabilities)),
      frame(.response, request: 2, session: 77, payload: responsePayload(value: 1)),
      frame(.response, request: 3, session: 77, payload: responsePayload(value: 1)),
      frame(.response, request: 4, session: 77, payload: responsePayload(value: 1)),
      frame(.response, request: 5, session: 77, payload: responsePayload(value: 1)),
    ]
    let member = DockWorkspaceTransitionMember(
      windowId: 42,
      from: CGAffineTransform(translationX: -100, y: -200),
      to: CGAffineTransform(translationX: -100, y: -900)
    )

    #expect(
      DockPayloadSession(transport: transport).runTransition(
        members: [member], durationNS: 2_000_000, frameIntervalNS: 1_000_000,
        nonce: nonce))
    #expect(transport.closed)
    #expect(transport.writes.count == 5)
    #expect(transport.writes[1].u16ForTest(72) == 1 << 6)
    #expect(transport.writes[2].u16ForTest(8) == 13)
    #expect(transport.writes[2].u16ForTest(72) == 1)
  }

  private func handshakePayload(nonce: Data, capabilities: UInt64) -> Data {
    var d = Data()
    d.append(contentsOf: withLE(UInt16(2)))
    d.append(contentsOf: withLE(UInt16(0)))
    d.append(contentsOf: withLE(UInt32(2)))
    d.append(contentsOf: withLE(capabilities))
    d.append(contentsOf: withLE(capabilities))
    d.append(contentsOf: withLE(UInt64(77)))
    d.append(contentsOf: withLE(UInt32(501)))
    d.append(contentsOf: withLE(UInt32(123)))
    d.append(contentsOf: withLE(UInt16(0)))
    d.append(contentsOf: withLE(UInt16(0)))
    d.append(nonce)
    d.append(contentsOf: [0, 0, 0, 0])
    return d
  }
  private func frame(
    _ type: DockPayloadProtocol.MessageType, request: UInt64, session: UInt64, payload: Data
  ) -> Data {
    DockPayloadProtocol.envelope(
      type: type, payloadBytes: payload.count, requestID: request, sessionID: session)! + payload
  }
  private func responsePayload(value: UInt64) -> Data {
    var data = Data()
    data.append(contentsOf: withLE(UInt16(0)))
    data.append(contentsOf: withLE(UInt16(0)))
    data.append(contentsOf: withLE(value))
    return data
  }
  private func withLE<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var v = value.littleEndian
    return Swift.withUnsafeBytes(of: &v) { Array($0) }
  }
}

private final class ScriptedTransport: DockPayloadTransport, @unchecked Sendable {
  var responses: [Data] = []
  var writes: [Data] = []
  var readRequests: [Int] = []
  var closed = false
  func writeAll(_ data: Data) -> Bool {
    writes.append(data)
    return true
  }
  func readExactly(_ count: Int) -> Data? {
    readRequests.append(count)
    guard !responses.isEmpty else { return nil }
    var first = responses.removeFirst()
    guard first.count >= count else { return nil }
    let result = first.prefix(count)
    if first.count > count {
      first.removeFirst(count)
      responses.insert(first, at: 0)
    }
    return Data(result)
  }
  func close() { closed = true }
}

extension Data {
  fileprivate func u16ForTest(_ offset: Int) -> UInt16? {
    guard offset + 2 <= count else { return nil }
    return subdata(in: offset..<offset + 2).withUnsafeBytes {
      UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))
    }
  }
  fileprivate func u64ForTest(_ offset: Int) -> UInt64? {
    guard offset + 8 <= count else { return nil }
    return subdata(in: offset..<offset + 8).withUnsafeBytes {
      UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
    }
  }
}

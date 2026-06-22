//
//  EventInjector.swift
//  AirBridge
//
//  Injects mouse and keyboard events using CGEvent APIs.
//

import Foundation
import CoreGraphics

enum MouseClickKind: String, Codable {
    case left, right, middle
}

enum PacketType: Codable, Equatable {
    case mouseMove(dx: Double, dy: Double)
    case mouseClick(kind: MouseClickKind)
    case scroll(dx: Double, dy: Double)
    case keyDown(keyCode: CGKeyCode)
    case keyUp(keyCode: CGKeyCode)
    case action(name: String)
    case swipe(fingers: Int, direction: String)
}

struct AirPacket: Codable {
    let deviceID: String
    let timestamp: TimeInterval
    let type: PacketType
}

/// Raw packet that includes HMAC for verification and canonicalization.
struct AirPacketRaw: Codable {
    let deviceID: String
    let timestamp: TimeInterval
    let type: PacketType
    let hmac: Data

    func canonicalDataForHMAC() -> Data {
        // Encode the structure without the HMAC field.
        // We split into two structs to avoid including hmac in the digest.
        let canonical = AirPacket(deviceID: deviceID, timestamp: timestamp, type: type)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(canonical)) ?? Data()
    }
}

final class EventInjector {
    enum InjectError: Error { case eventCreateFailed }

    func moveMouse(dx: Double, dy: Double) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let loc = CGEvent(source: nil)?.location ?? .zero
        let newPoint = CGPoint(x: loc.x + dx, y: loc.y + dy)
        // Ensure the mouse and cursor positions are associated (sometimes required for programmatic movement).
        _ = CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        // Move the cursor immediately; some apps/contexts only honor warping.
        CGWarpMouseCursorPosition(newPoint)

        // Choose dragged vs moved based on current button state.
        let leftDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let rightDown = CGEventSource.buttonState(.combinedSessionState, button: .right)
        let middleDown = CGEventSource.buttonState(.combinedSessionState, button: .center)
        let eventType: CGEventType
        let button: CGMouseButton
        if leftDown { eventType = .leftMouseDragged; button = .left }
        else if rightDown { eventType = .rightMouseDragged; button = .right }
        else if middleDown { eventType = .otherMouseDragged; button = .center }
        else { eventType = .mouseMoved; button = .left }

        guard let move = CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: newPoint, mouseButton: button) else { throw InjectError.eventCreateFailed }
        print("[EventInjector] moveMouse dx=\(dx) dy=\(dy) -> \(newPoint) type=\(eventType)")
        move.post(tap: .cghidEventTap)
    }

    func clickMouse(kind: MouseClickKind) throws {
        print("[EventInjector] clickMouse kind=\(kind)")
        let pos = CGEvent(source: nil)?.location ?? .zero
        let button: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch kind {
        case .left:
            button = .left; downType = .leftMouseDown; upType = .leftMouseUp
        case .right:
            button = .right; downType = .rightMouseDown; upType = .rightMouseUp
        case .middle:
            button = .center; downType = .otherMouseDown; upType = .otherMouseUp
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pos, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pos, mouseButton: button) else { throw InjectError.eventCreateFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double) throws {
        print("[EventInjector] scroll dx=\(dx) dy=\(dy)")
        // Use pixel-based scrolling for smooth trackpad-like behavior.
        let pixelsY = Int32(dy)
        let pixelsX = Int32(dx)
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: pixelsY, wheel2: pixelsX, wheel3: 0) else { throw InjectError.eventCreateFailed }
        ev.post(tap: .cghidEventTap)
    }

    func keyDown(keyCode: CGKeyCode) throws {
        print("[EventInjector] keyDown keyCode=\(keyCode)")
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { throw InjectError.eventCreateFailed }
        ev.post(tap: .cghidEventTap)
    }

    func keyUp(keyCode: CGKeyCode) throws {
        print("[EventInjector] keyUp keyCode=\(keyCode)")
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { throw InjectError.eventCreateFailed }
        ev.post(tap: .cghidEventTap)
    }
}

extension EventInjector {
    // Synthesizes a mouse button down event at the current cursor position.
    func mouseButtonDown(kind: MouseClickKind) throws {
        print("[EventInjector] mouseButtonDown kind=\(kind)")
        let pos = CGEvent(source: nil)?.location ?? .zero
        let button: CGMouseButton
        let downType: CGEventType
        switch kind {
        case .left:
            button = .left; downType = .leftMouseDown
        case .right:
            button = .right; downType = .rightMouseDown
        case .middle:
            button = .center; downType = .otherMouseDown
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pos, mouseButton: button) else {
            throw InjectError.eventCreateFailed
        }
        down.post(tap: .cghidEventTap)
    }

    // Synthesizes a mouse button up event at the current cursor position.
    func mouseButtonUp(kind: MouseClickKind) throws {
        print("[EventInjector] mouseButtonUp kind=\(kind)")
        let pos = CGEvent(source: nil)?.location ?? .zero
        let button: CGMouseButton
        let upType: CGEventType
        switch kind {
        case .left:
            button = .left; upType = .leftMouseUp
        case .right:
            button = .right; upType = .rightMouseUp
        case .middle:
            button = .center; upType = .otherMouseUp
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pos, mouseButton: button) else {
            throw InjectError.eventCreateFailed
        }
        up.post(tap: .cghidEventTap)
    }
}

extension EventInjector {
    // Routes an AirPacket to the appropriate injection behavior, including new swipe/action types.
    func handle(packet: AirPacket) throws {
        switch packet.type {
        case .mouseMove(let dx, let dy):
            try moveMouse(dx: dx, dy: dy)
        case .mouseClick(let kind):
            try clickMouse(kind: kind)
        case .scroll(let dx, let dy):
            try scroll(dx: dx, dy: dy)
        case .keyDown(let keyCode):
            try keyDown(keyCode: keyCode)
        case .keyUp(let keyCode):
            try keyUp(keyCode: keyCode)
        case .action(let name):
            try handleAction(name: name)
        case .swipe(let fingers, let direction):
            try handleSwipe(fingers: fingers, direction: direction)
        }
    }

    // Handles action payloads like "three_swipe_left/right/up/down".
    func handleAction(name: String) throws {
        print("[EventInjector] handleAction name=\(name)")
        switch name {
        case "three_swipe_left":
            try controlArrowLeft()
        case "three_swipe_right":
            try controlArrowRight()
        case "three_swipe_up":
            try controlArrowUp()
        case "three_swipe_down":
            try controlArrowDown()
        default:
            // Unknown action; ignore.
            break
        }
    }

    // Handles swipe payloads like fingers=3, direction="left/right/up/down".
    func handleSwipe(fingers: Int, direction: String) throws {
        print("[EventInjector] handleSwipe fingers=\(fingers) direction=\(direction)")
        // We currently only map three-finger swipes to Mission Control/Spaces actions.
        guard fingers == 3 else { return }
        switch direction.lowercased() {
        case "left":
            try controlArrowLeft()
        case "right":
            try controlArrowRight()
        case "up":
            try controlArrowUp()
        case "down":
            try controlArrowDown()
        default:
            break
        }
    }

    // MARK: - Control+Arrow helpers for Spaces / Mission Control

    func controlArrowLeft() throws { try pressControlArrow(123) }   // Left Arrow
    func controlArrowRight() throws { try pressControlArrow(124) }  // Right Arrow
    func controlArrowUp() throws { try pressControlArrow(126) }     // Up Arrow (Mission Control)
    func controlArrowDown() throws { try pressControlArrow(125) }   // Down Arrow (App Exposé)

    private func pressControlArrow(_ keyCode: CGKeyCode) throws {
        print("[EventInjector] pressControlArrow keyCode=\(keyCode)")
        let controlFlag: CGEventFlags = .maskControl
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw InjectError.eventCreateFailed
        }
        down.flags = controlFlag
        up.flags = controlFlag
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

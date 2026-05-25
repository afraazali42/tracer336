// ─────────────────────────────────────────────────────────────────────────────
// OverlayView.swift — Drag Feedback Rendering (Line, Dot, Label, Animations)
// ─────────────────────────────────────────────────────────────────────────────
//
// Custom NSView drawn on the OverlayWindow during a drag gesture. Renders:
//   - A white line from the icon center to the cursor position
//   - A glowing dot at the cursor end
//   - A pill-shaped label showing the selected duration (e.g. "3 min 22 sec")
//
// ANIMATIONS:
//   This view manages three independent animation systems, all timer-based
//   at 60fps using RunLoop timers in `.common` mode (works during tracking):
//
//   1. Expand/Retract — lineProgress (0→1 / 1→0)
//      Triggered when the cursor leaves/enters the icon during a drag.
//      Controls the scale of all visual elements.
//
//   2. Rubber Band — overshootOffset
//      Triggered once when the cursor crosses the max drag range.
//      Applies a spring-damped overshoot to the dot position along the
//      drag direction. Velocity-sensitive: slow = tiny nudge, fast = big snap.
//
//   3. Reel-Back — tape measure animation on release
//      The dot races back to the icon, line stays anchored. Used when
//      the user releases outside the icon to initiate an export.
//      Reports progress via onReelProgress (for icon rotation sync)
//      and fires onReelComplete when done (for momentum bounce + dismiss).
//
// COORDINATE SYSTEM:
//   All points are in the overlay window's local coordinates (bottom-left origin).
//   `startPoint` = icon center, `currentPoint` = cursor position (or reel target).
//
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

class OverlayView: NSView {
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Properties
    // ─────────────────────────────────────────────────────────────────────────
    
    /// The icon center in overlay-local coordinates. Set once at drag start.
    var startPoint: NSPoint?
    
    /// The current cursor position (or animated reel-back position) in overlay-local coords.
    var currentPoint: NSPoint?
    
    /// The selected duration in seconds. Updated live during drag, frozen during reel-back.
    var seconds: Int = 0
    
    /// Animation progress: 0 = nothing visible, 1 = fully expanded.
    /// Controls the scale/opacity of line, dot, and label.
    var lineProgress: CGFloat = 0.0
    
    /// Whether any animation timer is currently running.
    var isAnimating: Bool { animationTimer != nil }
    
    // ── Expand/Retract Animation ────────────────────────────────────────────
    
    /// Seconds to display during retract and reel-back (frozen when animation starts).
    private var retractSeconds: Int = 0
    
    private var animationFrom: CGFloat = 0.0
    private var animationTo: CGFloat = 1.0
    private var animationStartTime: CFTimeInterval = 0
    private var animationTimer: Timer?
    private var isRetractAnimation = false
    
    /// Duration for the expand animation (cursor leaves icon → line appears).
    private let expandDuration: CFTimeInterval = 0.5
    
    /// Duration for the retract animation (cursor returns to icon → line shrinks).
    private let retractDuration: CFTimeInterval = 0.25
    
    // ── Rubber Band Overshoot ───────────────────────────────────────────────
    
    /// Current overshoot offset in points, applied along `overshootDirection`.
    private var overshootOffset: CGFloat = 0.0
    
    /// Normalized direction vector from icon toward cursor at the moment of impact.
    private var overshootDirection: NSPoint = .zero
    
    private var overshootTimer: Timer?
    private var overshootStartTime: CFTimeInterval = 0
    private var overshootPeak: CGFloat = 0
    
    /// Total duration of the rubber band oscillation.
    private let overshootDuration: CFTimeInterval = 0.35
    
    /// Called each frame during rubber band with the offset in points.
    /// Use to sync external elements (e.g. icon rotation overshoot).
    var onOvershootUpdate: ((CGFloat) -> Void)?
    
    // ── Reel-Back Animation ─────────────────────────────────────────────────
    
    private var reelTimer: Timer?
    private var reelStartTime: CFTimeInterval = 0
    private var reelDuration: CFTimeInterval = 0.3
    private var reelStartPoint: NSPoint = .zero   // Dot position at release
    private var reelEndPoint: NSPoint = .zero      // Icon center (destination)
    private var reelStartRatio: CGFloat = 1.0      // Drag ratio at release
    
    /// Called each frame during reel-back with the current drag ratio (1.0→0.0).
    /// AppDelegate uses this to sync icon rotation backward.
    var onReelProgress: ((CGFloat) -> Void)?
    
    /// Called when the reel-back animation completes.
    /// AppDelegate uses this to trigger momentum bounce and dismiss the overlay.
    var onReelComplete: (() -> Void)?
    
    // ── Display Helpers ─────────────────────────────────────────────────────
    
    /// On 1x screens, thin translucent elements look washed out compared to Retina.
    /// This boosts opacity slightly to compensate.
    private var opacityBoost: CGFloat {
        let backing = self.window?.screen?.backingScaleFactor ?? 2.0
        return backing < 2.0 ? 1.25 : 1.0
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Expand / Retract Animation
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Animates `lineProgress` between 0 and 1 using timer-based interpolation.
    // The expand uses an exponential ease-out (fast start, gentle settle).
    // The retract uses a quadratic ease-in (visible longer, fast finish).
    
    /// Animate the line from its current progress to fully expanded (1.0).
    func startExpand() {
        if !isRetractAnimation && lineProgress > 0.99 { return }
        startAnimation(from: lineProgress, to: 1.0, duration: expandDuration)
    }
    
    /// Animate the line from its current progress back to invisible (0.0).
    func startRetract() {
        retractSeconds = seconds > 0 ? seconds : retractSeconds
        startAnimation(from: lineProgress, to: 0.0, duration: retractDuration)
    }
    
    private func startAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        animationFrom = from
        animationTo = to
        lineProgress = from
        isRetractAnimation = (to < from)
        animationStartTime = CACurrentMediaTime()
        animationTimer?.invalidate()
        
        // Scale duration proportionally if starting mid-animation
        let range = abs(to - from)
        let scaledDuration = duration * CFTimeInterval(range)
        guard scaledDuration > 0.01 else {
            lineProgress = to
            display()
            return
        }
        
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.animationStartTime
            let t = min(1.0, CGFloat(elapsed / scaledDuration))
            
            let eased: CGFloat
            if self.isRetractAnimation {
                eased = t * t                          // Quadratic ease-in
            } else {
                eased = 1.0 - pow(2.0, -10.0 * t)     // Exponential ease-out
            }
            
            self.lineProgress = self.animationFrom + (self.animationTo - self.animationFrom) * eased
            self.display()
            
            if t >= 1.0 {
                self.lineProgress = self.animationTo
                timer.invalidate()
                self.animationTimer = nil
                self.display()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Rubber Band Overshoot
    // ─────────────────────────────────────────────────────────────────────────
    //
    // When the cursor crosses the maximum drag range, a spring-damped oscillation
    // pushes the dot past the boundary and bounces back. The effect is velocity-
    // sensitive: slow drags get a gentle nudge, fast flicks get a visible snap.
    //
    // Physics model: peak * e^(-damping * t) * cos(frequency * π * t)
    //   - Peak scales with velocity (capped at 25pt)
    //   - Frequency increases with velocity (1π–3π)
    //   - Damping decreases with velocity (6–4), making fast hits springier
    
    /// Trigger a rubber band snap. Called once when the cursor first crosses max range.
    ///
    /// - Parameters:
    ///   - velocity: Cursor speed in points/sec at the moment of impact.
    ///   - direction: Normalized vector from icon center toward cursor.
    func triggerRubberBand(velocity: CGFloat, direction: NSPoint) {
        guard overshootTimer == nil else { return }
        
        let maxOvershoot: CGFloat = 25.0
        overshootPeak = min(maxOvershoot, velocity / 60.0)
        
        let bounceFrequency: CGFloat = 1.0 + min(2.0, velocity / 600.0)
        let damping: CGFloat = 6.0 - min(2.0, velocity / 500.0)
        
        overshootDirection = direction
        overshootStartTime = CACurrentMediaTime()
        
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.overshootStartTime
            let t = min(1.0, CGFloat(elapsed / self.overshootDuration))
            
            let decay = exp(-damping * t)
            let oscillation = cos(bounceFrequency * CGFloat.pi * t)
            self.overshootOffset = self.overshootPeak * decay * oscillation
            
            self.onOvershootUpdate?(self.overshootOffset)
            self.needsDisplay = true
            
            if t >= 1.0 {
                self.overshootOffset = 0
                self.onOvershootUpdate?(0)
                timer.invalidate()
                self.overshootTimer = nil
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        overshootTimer = timer
    }
    
    /// Cancel any active rubber band animation.
    func cancelRubberBand() {
        overshootTimer?.invalidate()
        overshootTimer = nil
        overshootOffset = 0
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Tape Measure Reel-Back
    // ─────────────────────────────────────────────────────────────────────────
    //
    // On release, the dot races back toward the icon while the line stays
    // anchored (lineProgress = 1.0). This creates a tape-measure retraction
    // effect. The easing uses a linear+quadratic blend for gentle acceleration
    // without the extreme slowness of pure cubic.
    //
    // Duration scales with distance: 60ms (short drag) to 180ms (full drag).
    
    /// Start the tape-measure reel-back animation.
    ///
    /// - Parameter fromRatio: The drag ratio (0–1) at the moment of release.
    ///   Controls animation speed and momentum bounce intensity.
    func startReelBack(fromRatio: CGFloat) {
        guard let current = currentPoint, let start = startPoint else { return }
        
        cancelRubberBand()
        animationTimer?.invalidate()
        animationTimer = nil
        
        reelStartPoint = current
        reelEndPoint = start
        reelStartRatio = fromRatio
        reelStartTime = CACurrentMediaTime()
        isRetractAnimation = true  // Tells draw() to use frozen retractSeconds for the label
        
        reelDuration = CFTimeInterval(0.06 + 0.12 * fromRatio)
        retractSeconds = seconds > 0 ? seconds : retractSeconds
        
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.reelStartTime
            let t = min(1.0, CGFloat(elapsed / self.reelDuration))
            
            // Blend of linear (40%) + quadratic (60%) for gentle acceleration
            let eased = 0.4 * t + 0.6 * t * t
            
            // Interpolate dot position from release point back to icon center
            let progress = 1.0 - eased
            self.currentPoint = NSPoint(
                x: self.reelEndPoint.x + (self.reelStartPoint.x - self.reelEndPoint.x) * progress,
                y: self.reelEndPoint.y + (self.reelStartPoint.y - self.reelEndPoint.y) * progress
            )
            
            // Keep lineProgress at 1.0 — the line stays anchored to the icon.
            // Only the dot position moves, so the line naturally shortens.
            self.lineProgress = 1.0
            
            // Report current ratio for icon rotation sync
            self.onReelProgress?(self.reelStartRatio * progress)
            self.needsDisplay = true
            
            if t >= 1.0 {
                self.lineProgress = 0
                self.currentPoint = self.reelEndPoint
                self.onReelProgress?(0)
                timer.invalidate()
                self.reelTimer = nil
                self.needsDisplay = true
                self.onReelComplete?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reelTimer = timer
    }
    
    /// Cancel any active reel-back animation.
    func cancelReel() {
        reelTimer?.invalidate()
        reelTimer = nil
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Drawing
    // ─────────────────────────────────────────────────────────────────────────
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let start = startPoint,
              let current = currentPoint else { return }
        
        let p = lineProgress
        guard p > 0.005 else { return }
        
        // Apply rubber band overshoot to the endpoint
        let drawPoint = NSPoint(
            x: current.x + overshootDirection.x * overshootOffset,
            y: current.y + overshootDirection.y * overshootOffset
        )
        
        // Dot at the (possibly overshooting) endpoint
        drawDot(at: drawPoint, scale: p)
        
        // Line from icon center toward the endpoint.
        // The origin interpolates based on lineProgress so the line "grows" from the icon.
        let lineOrigin = NSPoint(
            x: drawPoint.x + (start.x - drawPoint.x) * p,
            y: drawPoint.y + (start.y - drawPoint.y) * p
        )
        
        let linePath = NSBezierPath()
        linePath.move(to: lineOrigin)
        linePath.line(to: drawPoint)
        
        NSColor.white.withAlphaComponent(min(1.0, 0.8 * p * opacityBoost)).setStroke()
        linePath.lineWidth = 2.0
        linePath.stroke()
        
        // Duration label
        let displaySeconds = isRetractAnimation ? retractSeconds : seconds
        if displaySeconds > 0 {
            drawLabel(at: drawPoint, scale: p, totalSeconds: displaySeconds)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Drawing Helpers
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Draw a glowing white dot at the given point.
    func drawDot(at point: NSPoint, scale: CGFloat) {
        let maxRadius: CGFloat = 6.0
        let dotRadius = maxRadius * scale
        guard dotRadius > 0.1 else { return }
        
        let dotRect = NSRect(
            x: point.x - dotRadius,
            y: point.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        
        let dotOb: CGFloat = (self.window?.screen?.backingScaleFactor ?? 2.0) < 2.0 ? 1.25 : 1.0
        NSColor.white.withAlphaComponent(min(1.0, scale * dotOb)).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        
        // Glow halo
        let glowPadding: CGFloat = 3.0 * scale
        let glowRect = NSRect(
            x: point.x - dotRadius - glowPadding,
            y: point.y - dotRadius - glowPadding,
            width: (dotRadius + glowPadding) * 2,
            height: (dotRadius + glowPadding) * 2
        )
        NSColor.white.withAlphaComponent(0.2 * scale).setFill()
        NSBezierPath(ovalIn: glowRect).fill()
    }
    
    /// Draw a pill-shaped label showing the selected duration.
    ///
    /// The label automatically:
    ///   - Formats time intelligently (seconds → min:sec → hours)
    ///   - Flips to the left side if it would overflow the screen edge
    ///   - Scales from its own center during expand/retract animations
    ///   - Fades in text slightly after the pill background appears
    func drawLabel(at point: NSPoint, scale: CGFloat, totalSeconds: Int) {
        guard scale > 0.25 else { return }
        
        // ── Format time string ──────────────────────────────────────────
        let text: String
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            text = mins > 0 ? "\(hours) hr \(mins) min" : "\(hours) hr"
        } else if totalSeconds >= 600 {
            text = "\(mins) min"
        } else if mins > 0 {
            text = "\(mins) min \(secs) sec"
        } else {
            text = "\(secs) sec"
        }
        
        // ── Layout ──────────────────────────────────────────────────────
        let fontSize: CGFloat = 13
        let alpha = scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 10
        let labelOffset: CGFloat = 14  // Gap between dot and label
        
        var targetRect = NSRect(
            x: point.x + labelOffset,
            y: point.y - size.height / 2 - padding / 2,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        
        // Flip to left side if label would overflow the right edge
        if targetRect.maxX > bounds.maxX - 10 {
            targetRect.origin.x = point.x - labelOffset - targetRect.width
        }
        // Keep above the bottom edge
        if targetRect.minY < bounds.minY + 10 {
            targetRect.origin.y = bounds.minY + 10
        }
        
        // Scale the pill from its center (not toward the dot)
        let scaledWidth = targetRect.width * scale
        let scaledHeight = targetRect.height * scale
        let scaledRect = NSRect(
            x: targetRect.midX - scaledWidth / 2,
            y: targetRect.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        
        // ── Draw pill background ────────────────────────────────────────
        let cornerRadius = scaledRect.height / 2
        
        NSColor.black.withAlphaComponent(0.75 * alpha).setFill()
        NSBezierPath(roundedRect: scaledRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        
        // Subtle border (only visible at larger scales)
        if scale > 0.5 {
            NSColor.white.withAlphaComponent(0.15 * (scale - 0.5) * 2.0).setStroke()
            let borderPath = NSBezierPath(roundedRect: scaledRect, xRadius: cornerRadius, yRadius: cornerRadius)
            borderPath.lineWidth = 0.5
            borderPath.stroke()
        }
        
        // ── Draw text (fades in slightly after the pill) ────────────────
        if scale > 0.4 {
            let textAlpha = min(1.0, (scale - 0.4) / 0.6)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(textAlpha)
            ]
            
            let textX = scaledRect.origin.x + (scaledRect.width - size.width) / 2
            let textY = scaledRect.origin.y + (scaledRect.height - size.height) / 2
            text.draw(at: NSPoint(x: textX, y: textY), withAttributes: textAttrs)
        }
    }
}

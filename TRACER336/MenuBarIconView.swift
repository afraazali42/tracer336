// ─────────────────────────────────────────────────────────────────────────────
// MenuBarIconView.swift — Animated Menu Bar Icon
// ─────────────────────────────────────────────────────────────────────────────
//
// The TRACER336 menu bar icon is composed of three independently animated
// CALayers stacked in the status bar button:
//
//   ┌─────────────────┐
//   │  Outer Ring      │  ← Rotates counter-clockwise during drag
//   │  ┌───────────┐  │
//   │  │ Middle Ring│  │  ← Rotates clockwise during drag (opposite)
//   │  │  ┌─────┐  │  │
//   │  │  │ Dot │  │  │  ← Static center dot (hidden when paused/error)
//   │  │  └─────┘  │  │
//   │  └───────────┘  │
//   └─────────────────┘
//
// VISUAL STATES:
//   .active  — Full white opacity, all three layers visible
//   .paused  — Rings dimmed to 35%, center dot hidden
//   .error   — Rings at 60% with red overlay, center dot hidden
//              (triggered when the selected audio device is disconnected)
//
// ANIMATIONS:
//   - Drag rotation: rings rotate proportionally to drag distance (spool metaphor)
//   - Snap-back: ease-out return to zero on cancelled drags
//   - Momentum bounce: spring overshoot past zero when reel-back hits the icon
//   - Success pulse: staggered scale+opacity blink radiating center→middle→outer
//
// LAYER STRUCTURE:
//   All three artwork layers use template rendering (white artwork, system-tinted).
//   The SVG assets are in Assets.xcassets with "preserves-vector-representation"
//   enabled for crisp rendering at any size. Red overlays for the error state
//   are lazily created on first use and masked to the ring shapes.
//
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

class MenuBarIconView: NSView {
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Layer Properties
    // ─────────────────────────────────────────────────────────────────────────
    
    private let outerRingLayer = CALayer()
    private let middleRingLayer = CALayer()
    private let centerDotLayer = CALayer()
    
    /// Current rotation angles — tracked so snap-back/momentum animations
    /// know where to animate from.
    private var currentOuterAngle: CGFloat = 0
    private var currentMiddleAngle: CGFloat = 0
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Initialization
    // ─────────────────────────────────────────────────────────────────────────
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    /// Load the three SVG artwork images from the asset catalog and configure
    /// their CALayers centered in the view with 0.5/0.5 anchor points.
    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        
        guard let outerImage = NSImage(named: "MenuBarOuterRing"),
              let middleImage = NSImage(named: "MenuBarMiddleRing"),
              let centerImage = NSImage(named: "MenuBarCenter") else {
            Log.error("Failed to load menu bar icon images from asset catalog", category: .ui)
            return
        }
        
        let w = bounds.width
        let h = bounds.height
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        func configureLayer(_ layer: CALayer, image: NSImage) {
            layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            layer.position = CGPoint(x: w / 2, y: h / 2)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)  // Rotate around center
            layer.contents = image.layerContents(forContentsScale: scale)
            layer.contentsGravity = .resizeAspect
        }
        
        configureLayer(outerRingLayer, image: outerImage)
        configureLayer(middleRingLayer, image: middleImage)
        configureLayer(centerDotLayer, image: centerImage)
        
        // Stack order: outer (back) → middle → dot (front)
        layer?.addSublayer(outerRingLayer)
        layer?.addSublayer(middleRingLayer)
        layer?.addSublayer(centerDotLayer)
    }
    
    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let cx = w / 2
        let cy = h / 2
        
        for sub in [outerRingLayer, middleRingLayer, centerDotLayer] {
            sub.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            sub.position = CGPoint(x: cx, y: cy)
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Icon State (Active / Paused / Error)
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Red-tinted overlay layers for the error state. Created lazily on first use.
    /// Each is a solid red rectangle masked to the ring shape.
    private var outerRedOverlay: CALayer?
    private var middleRedOverlay: CALayer?
    
    /// Create a red overlay layer masked to the shape of the given artwork image.
    private func createRedOverlay(for image: NSImage) -> CALayer {
        let w = bounds.width
        let h = bounds.height
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let overlay = CALayer()
        overlay.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        overlay.position = CGPoint(x: w / 2, y: h / 2)
        overlay.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        overlay.backgroundColor = CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)
        overlay.opacity = 0
        
        let maskLayer = CALayer()
        maskLayer.bounds = overlay.bounds
        maskLayer.position = CGPoint(x: w / 2, y: h / 2)
        maskLayer.contents = image.layerContents(forContentsScale: scale)
        maskLayer.contentsGravity = .resizeAspect
        overlay.mask = maskLayer
        
        return overlay
    }
    
    /// Lazily create the red overlay layers on first error state.
    private func ensureRedOverlays() {
        guard outerRedOverlay == nil else { return }
        guard let outerImage = NSImage(named: "MenuBarOuterRing"),
              let middleImage = NSImage(named: "MenuBarMiddleRing") else { return }
        
        let oo = createRedOverlay(for: outerImage)
        let mo = createRedOverlay(for: middleImage)
        
        layer?.addSublayer(oo)
        layer?.addSublayer(mo)
        
        outerRedOverlay = oo
        middleRedOverlay = mo
    }
    
    /// The three visual states the icon can be in.
    enum IconState {
        case active   // Recording — full white, all layers visible
        case paused   // Paused — dimmed rings, no center dot
        case error    // Device disconnected — red rings, no center dot
    }
    
    /// Transition the icon to a new visual state with a 0.3s animated crossfade.
    func setState(_ state: IconState) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        
        switch state {
        case .active:
            outerRingLayer.opacity = 1.0
            middleRingLayer.opacity = 1.0
            centerDotLayer.opacity = 1.0
            outerRedOverlay?.opacity = 0
            middleRedOverlay?.opacity = 0
            
        case .paused:
            outerRingLayer.opacity = 0.35
            middleRingLayer.opacity = 0.35
            centerDotLayer.opacity = 0.0
            outerRedOverlay?.opacity = 0
            middleRedOverlay?.opacity = 0
            
        case .error:
            ensureRedOverlays()
            outerRingLayer.opacity = 0.6
            middleRingLayer.opacity = 0.6
            centerDotLayer.opacity = 0.0
            outerRedOverlay?.opacity = 1.0
            middleRedOverlay?.opacity = 1.0
        }
        
        CATransaction.commit()
    }
    
    /// Convenience method — sets active or paused based on a boolean.
    func setRecordingActive(_ active: Bool) {
        setState(active ? .active : .paused)
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Save Success Pulse
    // ─────────────────────────────────────────────────────────────────────────
    //
    // A staggered inside-out ripple animation that confirms a successful export.
    // Each layer blinks twice (opacity 0→1→0→1) with a scale punch, and each
    // starts slightly after the previous to create a wave radiating from center.
    //
    // Timing:
    //   Center dot:   t=0.00s  scalePeak=1.6x
    //   Middle ring:  t=0.10s  scalePeak=1.18x
    //   Outer ring:   t=0.20s  scalePeak=1.10x
    //   Total duration: ~1.0s
    
    /// Play the success pulse animation. Safe to call at any time.
    func pulseSuccess() {
        let pulseDuration = 0.8
        let stagger = 0.1
        
        animateElementPulse(layer: centerDotLayer, scalePeak: 1.6,
                            duration: pulseDuration, delay: 0)
        animateElementPulse(layer: middleRingLayer, scalePeak: 1.18,
                            duration: pulseDuration, delay: stagger)
        animateElementPulse(layer: outerRingLayer, scalePeak: 1.10,
                            duration: pulseDuration, delay: stagger * 2)
    }
    
    /// Animate a single layer with a double-blink scale+opacity pulse.
    private func animateElementPulse(layer: CALayer, scalePeak: CGFloat, duration: Double, delay: Double) {
        let baseOpacity = layer.opacity
        
        // Scale: two punches — first at full intensity, second at half
        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = [
            1.0, scalePeak, 1.0,
            1.0 + (scalePeak - 1.0) * 0.5,
            0.97, 1.0
        ]
        scaleAnim.keyTimes = [0, 0.15, 0.35, 0.50, 0.75, 1.0]
        scaleAnim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        
        // Opacity: two blinks — down→up→down→up
        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [baseOpacity, 0.0, 1.0, 0.0, 1.0, baseOpacity]
        opacityAnim.keyTimes = [0, 0.12, 0.28, 0.42, 0.58, 1.0]
        opacityAnim.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        
        layer.add(group, forKey: "successPulse")
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Drag-Driven Rotation (Spool Metaphor)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // During a drag, the rings rotate proportionally to the drag distance,
    // like a tape spool unwinding. The outer ring rotates counter-clockwise
    // and the middle ring rotates clockwise (opposite directions) to create
    // a mechanical feel.
    //
    // The rotation is purely distance-based, not velocity-based. Same distance
    // = same rotation regardless of drag speed.
    
    /// Set the icon rotation based on the current drag ratio (0–1).
    ///
    /// - Parameter ratio: 0.0 = at icon (no rotation), 1.0 = max range (full rotation)
    func setDragRatio(_ ratio: CGFloat) {
        // Clear any competing animations
        outerRingLayer.removeAnimation(forKey: "snapBack")
        middleRingLayer.removeAnimation(forKey: "snapBack")
        outerRingLayer.removeAnimation(forKey: "momentum")
        middleRingLayer.removeAnimation(forKey: "momentum")
        
        // At full drag: outer = 3/4 turn (270°), middle = 1 full turn (360°)
        let outerAngle = ratio * CGFloat.pi * 1.5     // Counter-clockwise
        let middleAngle = -ratio * CGFloat.pi * 2.0    // Clockwise (opposite)
        
        currentOuterAngle = outerAngle
        currentMiddleAngle = middleAngle
        
        // Instant transform update — no animation lag
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerRingLayer.transform = CATransform3DMakeRotation(outerAngle, 0, 0, 1)
        middleRingLayer.transform = CATransform3DMakeRotation(middleAngle, 0, 0, 1)
        CATransaction.commit()
    }
    
    /// Animate rings back to zero rotation with ease-out timing.
    /// Duration scales with current rotation angle.
    func snapBack() {
        let outerAngle = currentOuterAngle
        let middleAngle = currentMiddleAngle
        
        let maxAngle = max(abs(outerAngle), abs(middleAngle))
        let duration = min(0.5, max(0.15, Double(maxAngle) / (CGFloat.pi * 2.0) * 0.5))
        
        let outerBack = CABasicAnimation(keyPath: "transform.rotation.z")
        outerBack.fromValue = outerAngle
        outerBack.toValue = 0
        outerBack.duration = duration
        outerBack.timingFunction = CAMediaTimingFunction(name: .easeOut)
        outerRingLayer.add(outerBack, forKey: "snapBack")
        outerRingLayer.transform = CATransform3DIdentity
        
        let middleBack = CABasicAnimation(keyPath: "transform.rotation.z")
        middleBack.fromValue = middleAngle
        middleBack.toValue = 0
        middleBack.duration = duration
        middleBack.timingFunction = CAMediaTimingFunction(name: .easeOut)
        middleRingLayer.add(middleBack, forKey: "snapBack")
        middleRingLayer.transform = CATransform3DIdentity
        
        currentOuterAngle = 0
        currentMiddleAngle = 0
    }
    
    /// Momentum overshoot: rings spin past zero and spring back.
    /// Called after the reel-back animation delivers the line back to the icon.
    ///
    /// - Parameter fromRatio: The drag ratio at release. Controls overshoot intensity.
    func momentumBounce(fromRatio: CGFloat) {
        outerRingLayer.removeAnimation(forKey: "snapBack")
        middleRingLayer.removeAnimation(forKey: "snapBack")
        
        // Overshoot in the opposite direction (backward past resting position)
        let overshoot = fromRatio * CGFloat.pi * 0.3  // Max ~54° at full drag
        let outerOvershoot = -overshoot
        let middleOvershoot = overshoot * 1.3  // Middle gets slightly more
        
        let duration = 0.35
        
        // Keyframe: 0 → overshoot → small counter-bounce → settle at 0
        let outerBounce = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        outerBounce.values = [0, outerOvershoot, outerOvershoot * -0.2, 0]
        outerBounce.keyTimes = [0, 0.35, 0.7, 1.0]
        outerBounce.duration = duration
        outerBounce.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        outerRingLayer.add(outerBounce, forKey: "momentum")
        outerRingLayer.transform = CATransform3DIdentity
        
        let middleBounce = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        middleBounce.values = [0, middleOvershoot, middleOvershoot * -0.2, 0]
        middleBounce.keyTimes = [0, 0.35, 0.7, 1.0]
        middleBounce.duration = duration
        middleBounce.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        middleRingLayer.add(middleBounce, forKey: "momentum")
        middleRingLayer.transform = CATransform3DIdentity
        
        currentOuterAngle = 0
        currentMiddleAngle = 0
    }
}

import AppKit
internal import GraphModel
internal import GraphTypes
@_spi(GraphApp) internal import ThubanGraphKit

/// Timing probes for the app's smoke run (slider drags and 3D camera orbits inside Study, on the shared engine).
/// They drive the sessions with the commands the list's slider and the 3D view's drag send.
extension StudyGraphHost {
    public struct StepTiming: Sendable, CustomStringConvertible {
        public var steps: Int
        public var meanMilliseconds: Double
        public var maxMilliseconds: Double
        public var description: String {
            String(format: "%d steps, mean %.1f ms, max %.1f ms", steps, meanMilliseconds, maxMilliseconds)
        }
    }

    /// Moves slider row `id` through `values` (`setSliderValue`, the slider fast path). Each step waits until the
    /// value has reached the sampler and the main actor has turned once. Nil when no session holds the row.
    public func timeSliderDrag(id: String, values: [Double]) async -> StepTiming? {
        guard let embed = [twoD, threeD].first(where: { $0.document.item(ExpressionID(id))?.slider != nil }) else { return nil }
        return await timeSteps(values.count) { index in
            embed.session.perform(.setSliderValue(ExpressionID(id), values[index]))
            await embed.session.flushParameters()
        }
    }

    /// Orbits the 3D camera by `degrees` per step, `steps` times (as a rotate drag does).
    public func timeOrbit(steps: Int, degrees: Double) async -> StepTiming {
        let embed = threeD
        return await timeSteps(steps) { _ in
            var camera = embed.document.viewport3D
            camera.azimuth += degrees * .pi / 180
            embed.session.perform(.setViewport3D(camera))
        }
    }

    private func timeSteps(_ count: Int, _ step: @MainActor (Int) async -> Void) async -> StepTiming {
        let clock = ContinuousClock()
        var total = 0.0, worst = 0.0
        for index in 0 ..< count {
            let start = clock.now
            await step(index)
            await Task.yield()
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            total += ms
            worst = max(worst, ms)
        }
        return StepTiming(steps: count, meanMilliseconds: count == 0 ? 0 : total / Double(count), maxMilliseconds: worst)
    }
}

/// Offscreen render of the 3D graph's Metal view (smoke screenshots): `cacheDisplay` cannot read it, and its own
/// `snapshotImage()` follows the window's backing scale, which is 1 on a 1x display.
public enum StudyGraphSnapshot {
    /// `view` (the 3D graph's Metal view) rendered at `bounds` × `scale` pixels, overlays included; nil for any
    /// other view or without Metal.
    @MainActor public static func image(of view: NSView, scale: CGFloat) -> CGImage? {
        guard let view = view as? Graph3DMTKView, let renderer = view.renderer, let model = view.model,
              let session = model.session, view.bounds.width >= 1, view.bounds.height >= 1,
              let graph = renderer.renderImage(camera: model.camera(session), size: view.bounds.size, scale: scale)
        else { return nil }
        guard let overlay = view.overlaySnapshot?(view.bounds.size, scale) else { return graph }
        return Graph3DMTKView.composite(graph, overlay)
    }
}

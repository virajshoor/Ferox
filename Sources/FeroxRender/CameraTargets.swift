import FeroxCore
import FeroxScene

/// Cameras that render into a texture instead of the screen. Selection matches the screen
/// camera's activity rules (`isActiveInHierarchy`) but keeps only cameras whose
/// `renderTarget` is set. Order is priority, then lowest entity index.
public struct OffscreenCamera: Equatable, Sendable {
    public var entity: Entity
    public var camera: Camera
    public var target: AssetID
    public init(entity: Entity, camera: Camera, target: AssetID) {
        self.entity = entity
        self.camera = camera
        self.target = target
    }
}

public enum CameraTargets {
    /// Pixel size of an offscreen camera. A positive `targetSize` wins; otherwise the screen size.
    public static func resolution(_ camera: Camera, screenWidth: Int, screenHeight: Int) -> (width: Int, height: Int) {
        if let size = camera.targetSize {
            return (max(size.width, 1), max(size.height, 1))
        }
        return (max(screenWidth, 1), max(screenHeight, 1))
    }

    public static func offscreen(in world: World) -> [OffscreenCamera] {
        var found: [OffscreenCamera] = []
        world.read(Camera.self) { entity, camera in
            guard let target = camera.renderTarget, world.isActiveInHierarchy(entity) else { return }
            found.append(OffscreenCamera(entity: entity, camera: camera, target: target))
        }
        found.sort { lhs, rhs in
            if lhs.camera.priority != rhs.camera.priority { return lhs.camera.priority > rhs.camera.priority }
            return lhs.entity < rhs.entity
        }
        return found
    }
}

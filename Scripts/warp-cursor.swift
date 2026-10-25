import CoreGraphics
import Foundation
let to = CGPoint(x: 480, y: 420)
CGWarpMouseCursorPosition(to)
CGAssociateMouseAndMouseCursorPosition(0)
CGAssociateMouseAndMouseCursorPosition(1)
usleep(200_000)
print("warped to:", CGEvent(source: nil)?.location ?? .zero)

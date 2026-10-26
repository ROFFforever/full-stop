import Foundation
import CoreGraphics // CGRect.

// Tells a sign for your lane from a sign for somewhere else, by where its box sits in the frame.
//
// The camera looks down the road, so the far end of the road is near the middle of the picture. Driving forward, things
// slide away from that point: a sign on the right of the road drifts right as it grows, a sign on the left drifts left.
// The sign you must stop for is on the right (or straight ahead at a T). A sign on the left controls other traffic: oncoming
// cars (you see its back) or another road. Pure math, so it also runs in the Mac replay tool.
//
// Known limit: this ignores the legal stop signs on the left (the extra sign on a one-way street, the median of a
// multi-lane road). Drivers on those roads would need this loosened. Check against 4 recordings: of 23 sign tracks that
// started on the right, none crossed to the left.
enum SignPosition {
    static let minCenterX = 0.45 // Box centre, 0 = left edge of the frame, 1 = right edge. Right-lane signs start at about 0.5.

    static func isOnYourSide(box: CGRect) -> Bool { box.midX >= minCenterX }
}

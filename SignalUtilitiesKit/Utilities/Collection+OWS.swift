//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation

public extension Collection {

    /// Returns the element at the specified index iff it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

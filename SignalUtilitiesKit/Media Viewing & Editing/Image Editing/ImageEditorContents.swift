//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.

import UIKit
import SessionUtilitiesKit

// ImageEditorContents represents a snapshot of canvas
// state.
//
// Instances of ImageEditorContents should be treated
// as immutable, once configured.
public class ImageEditorContents {

    public typealias ItemMapType = OrderedDictionary<String, ImageEditorItem>

    // This represents the current state of each item,
    // a mapping of [itemId : item].
    var itemMap = ItemMapType()

    // Used to create an initial, empty instances of this class.
    public init() {
    }

    // Used to clone copies of instances of this class.
    public init(itemMap: ItemMapType) {
        self.itemMap = itemMap
    }

    // Since the contents are immutable, we only modify copies
    // made with this method.
    public func clone() -> ImageEditorContents {
        return ImageEditorContents(itemMap: itemMap.clone())
    }

    public func item(forId itemId: String) -> ImageEditorItem? {
        return itemMap.value(forKey: itemId)
    }

    public func append(item: ImageEditorItem) {
        Log.verbose("[ImageEditorContents] append: \(item.itemId)")

        itemMap.append(key: item.itemId, value: item)
    }

    public func replace(item: ImageEditorItem) {
        Log.verbose("[ImageEditorContents] replace: \(item.itemId)")

        itemMap.replace(key: item.itemId, value: item)
    }

    public func remove(item: ImageEditorItem) {
        Log.verbose("[ImageEditorContents] remove: \(item.itemId)")

        itemMap.remove(key: item.itemId)
    }

    public func remove(itemId: String) {
        Log.verbose("[ImageEditorContents] remove: \(itemId)")

        itemMap.remove(key: itemId)
    }

    public func itemCount() -> Int {
        return itemMap.count
    }

    public func items() -> [ImageEditorItem] {
        return itemMap.orderedValues
    }

    public func itemIds() -> [String] {
        return itemMap.orderedKeys
    }
}

//
//  Item.swift
//  ikuyo-live-wallpaper
//
//  Created by Paul Frank Pacheco Carpio on 27/06/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

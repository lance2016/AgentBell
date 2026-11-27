import SwiftUI

// Use SwiftUI's property wrapper so standalone Command Line Tools can build
// with the macOS 27 SDK even when the SwiftUI macro plugin is unavailable.
typealias ViewState<Value> = SwiftUI.State<Value>

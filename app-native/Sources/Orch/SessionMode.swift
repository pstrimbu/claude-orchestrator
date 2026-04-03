import Foundation

enum SessionMode {
    case new
    case continue_
    case resume(id: String)
}

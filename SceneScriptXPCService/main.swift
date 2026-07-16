import Foundation

let delegate = SceneScriptXPCListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
dispatchMain()

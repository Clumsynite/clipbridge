// Puts text on the general pasteboard marked as concealed, the way password managers do
// (nspasteboard.org). ClipBridge must refuse to serve it.
//   swift scripts/set-concealed.swift [text]
import AppKit

let text = CommandLine.arguments.dropFirst().first ?? "hunter2"
let pb = NSPasteboard.general
pb.clearContents()
pb.setString(text, forType: .string)
pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

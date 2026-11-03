import Carbon
import Foundation

// 入力ソースを扱う小さな道具。install_user.sh から使う。
//   current               いま選ばれている入力ソースのIDを表示する
//   install <app path>    入力メソッドを登録し、その入力ソースを有効にする
//   select <id>           入力ソースを選ぶ

func string(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func sources(id: String) -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "current":
    print(string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID) ?? "")
case "install" where arguments.count > 2:
    let status = TISRegisterInputSource(URL(fileURLWithPath: arguments[2]) as CFURL)
    guard status == noErr else {
        FileHandle.standardError.write("登録に失敗しました: \(status)\n".data(using: .utf8)!)
        exit(1)
    }
    let filter = [kTISPropertyBundleID as String: "dev.ensan.inputmethod.azooKeyMac"] as CFDictionary
    for source in (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? [] {
        TISEnableInputSource(source)
    }
case "select" where arguments.count > 2:
    guard let source = sources(id: arguments[2]).first else {
        FileHandle.standardError.write("入力ソースが見つかりません: \(arguments[2])\n".data(using: .utf8)!)
        exit(1)
    }
    TISEnableInputSource(source)
    let status = TISSelectInputSource(source)
    guard status == noErr else {
        FileHandle.standardError.write("入力ソースを選べませんでした: \(status)\n".data(using: .utf8)!)
        exit(1)
    }
default:
    FileHandle.standardError.write("usage: input_source current | install <app path> | select <id>\n".data(using: .utf8)!)
    exit(2)
}

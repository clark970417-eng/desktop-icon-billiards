import Foundation

enum AppLanguage: String, CaseIterable {
    case zhHans, en
    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .zhHans
    }
    func text(_ simplifiedChinese: String, _ english: String) -> String {
        self == .en ? english : simplifiedChinese
    }
}

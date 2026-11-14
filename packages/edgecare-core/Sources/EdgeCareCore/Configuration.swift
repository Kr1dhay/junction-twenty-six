import Foundation
public struct AppConfiguration: Sendable {
    public enum Chain: String, Sendable { case mock, demoHTTP, devnet }
    public enum LLM: String, Sendable { case ondevice, gemini }
    public let demoMode: Bool
    public let offline: Bool
    public let chain: Chain
    public let llm: LLM
    public var allowsNetwork: Bool { !demoMode && !offline }
    public init(demoMode: Bool = true, offline: Bool = true, chain: Chain = .mock, llm: LLM = .ondevice) throws {
        guard !(demoMode || offline) || (chain == .mock && llm == .ondevice) else { throw CoreError.invalidConfiguration }
        self.demoMode = demoMode; self.offline = offline; self.chain = chain; self.llm = llm
    }
    public static let demo = try! AppConfiguration()
    public static let connectedDemo = try! AppConfiguration(demoMode: false, offline: false, chain: .demoHTTP)
}

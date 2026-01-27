import ArgumentParser
import DogecoinKit

enum NetworkOption: String, ExpressibleByArgument, CaseIterable {
    case mainnet
    case testnet

    var value: DogecoinNetwork {
        switch self {
        case .mainnet: .mainnet
        case .testnet: .testnet
        }
    }
}

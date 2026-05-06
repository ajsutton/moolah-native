// Shared/CryptoImport/TransferDirection.swift
import Foundation

/// Direction a single Alchemy transfer takes relative to the synced
/// wallet. Computed from the lowercased `from` / `to` fields.
///
/// Lives in its own file so `TransferEventBuilder.swift` stays under
/// SwiftLint's `file_length` budget after the merge of issues #754
/// (`SignAndCounterparty`) and #762 (`BuilderServices`).
enum TransferDirection: Sendable {
  case outbound
  case inbound
  case selfSend
  case unrelated

  init(fromAddress: String, toAddress: String?, walletAddress: String) {
    let from = fromAddress.lowercased()
    let to = toAddress?.lowercased()
    let fromIsUs = from == walletAddress
    let toIsUs = to == walletAddress
    switch (fromIsUs, toIsUs) {
    case (true, true): self = .selfSend
    case (true, false): self = .outbound
    case (false, true): self = .inbound
    case (false, false): self = .unrelated
    }
  }
}

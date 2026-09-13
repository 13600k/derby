import Foundation

extension Router {
    /// Moves the copy of a model on `account` ahead of the other copies of that
    /// model, keeping every other target where the strategy put it.
    ///
    /// A conversation's encrypted reasoning can only be read back by the account
    /// that issued it, and its cached prompt is there too, so a conversation
    /// moved to another copy mid-way has its history processed again and loses
    /// its thinking. Which model answers remains the strategy's decision.
    static func preferConversationAccount(_ ranked: [RankedTarget], account: UUID)
        -> (ranked: [RankedTarget], firstMove: (winner: String, loser: String)?) {
        var out = ranked
        var groups: [String: [Int]] = [:]
        for (index, candidate) in ranked.enumerated() {
            let lineage = candidate.target.lineage
            guard lineage.isKnown else { continue }
            groups[lineage.identity, default: []].append(index)
        }
        var firstMove: (winner: String, loser: String)?
        for positions in groups.values.sorted(by: { $0[0] < $1[0] }) where positions.count > 1 {
            let members = positions.map { ranked[$0] }
            guard let holder = members.firstIndex(where: { $0.target.account.id == account }), holder > 0 else { continue }
            var reordered = members
            let kept = reordered.remove(at: holder)
            reordered.insert(kept, at: 0)
            for (slot, position) in positions.enumerated() { out[position] = reordered[slot] }
            if firstMove == nil { firstMove = (kept.target.label, members[0].target.label) }
        }
        return (out, firstMove)
    }
}

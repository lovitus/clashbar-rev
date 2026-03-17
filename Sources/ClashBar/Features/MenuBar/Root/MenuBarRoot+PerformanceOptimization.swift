import SwiftUI

// Performance optimization helper class for MenuBarRoot
@MainActor
class ProxyGroupCache: ObservableObject {
    @Published var cachedNodesForGroup: [String: [String]] = [:]
    @Published var cachedLatencyForNode: [String: (text: String, value: Int?)] = [:]
    
    func updateCachedNodesForGroup(_ group: ProxyGroup, sortGroupNodesByLatency: Bool, appState: AppState, sortedGroupNodes: (ProxyGroup) -> [String], defaultGroupNodes: (ProxyGroup) -> [String]) {
        let nodes = sortGroupNodesByLatency
            ? sortedGroupNodes(group)
            : defaultGroupNodes(group)
        cachedNodesForGroup[group.name] = nodes
        
        // Pre-cache latency values for all nodes in this group
        for node in nodes {
            let key = "\(group.name)-\(node)"
            let delayValue = appState.delayValue(group: group.name, node: node)
            let delayText = appState.delayText(group: group.name, node: node)
            cachedLatencyForNode[key] = (text: delayText, value: delayValue)
        }
    }
    
    func updateCachedLatencyForGroup(_ group: ProxyGroup, appState: AppState) {
        guard let nodes = cachedNodesForGroup[group.name] else { return }
        
        for node in nodes {
            let key = "\(group.name)-\(node)"
            let delayValue = appState.delayValue(group: group.name, node: node)
            let delayText = appState.delayText(group: group.name, node: node)
            cachedLatencyForNode[key] = (text: delayText, value: delayValue)
        }
    }
}

// Performance optimization extension for MenuBarRoot
extension MenuBarRoot {
    // Update cached proxy groups when relevant data changes
    func updateCachedProxyGroups() {
        let groups = filteredGroups(from: appState.proxyGroups)
        // Note: This would need to be a @State variable in the main struct
        // For now, we'll rely on the existing filteredProxyGroups
    }

// Modified proxy group row with performance optimizations
struct OptimizedProxyGroupRow: View {
    let group: ProxyGroup
    let appState: AppState
    let sortGroupNodesByLatency: Bool
    let hideHiddenProxyGroups: Bool
    
    @State private var cachedNodes: [String] = []
    @State private var cachedNodeLatencies: [String: (text: String, value: Int?)] = [:]
    @State private var isPopoverVisible = false
    
    private func updateCache() {
        // Use existing sortedGroupNodes and defaultGroupNodes from MenuBarRoot
        let nodes = sortGroupNodesByLatency
            ? sortedGroupNodes(group)
            : defaultGroupNodes(group)
        
        if cachedNodes != nodes {
            cachedNodes = nodes
            
            // Pre-compute latency values
            var newLatencies: [String: (text: String, value: Int?)] = [:]
            for node in nodes {
                let delayValue = appState.delayValue(group: group.name, node: node)
                let delayText = appState.delayText(group: group.name, node: node)
                newLatencies[node] = (text: delayText, value: delayValue)
            }
            cachedNodeLatencies = newLatencies
        }
    }
    
    var body: some View {
        // Implementation would go here
        EmptyView()
    }
}

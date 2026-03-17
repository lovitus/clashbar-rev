import SwiftUI

// Performance optimization extension for MenuBarRoot
extension MenuBarRoot {
    // Cached computed properties to avoid repeated calculations
    @State private var cachedProxyGroups: [ProxyGroup] = []
    @State private var cachedNodesForGroup: [String: [String]] = [:]
    @State private var cachedLatencyForNode: [String: (text: String, value: Int?)] = [:]
    @State private var lastCacheUpdate: Date = Date()
    
    // Update cached proxy groups when relevant data changes
    func updateCachedProxyGroups() {
        let groups = filteredGroups(from: appState.proxyGroups)
        if cachedProxyGroups != groups {
            cachedProxyGroups = groups
            // Clear group-specific caches when groups change
            cachedNodesForGroup.removeAll(keepingCapacity: true)
            cachedLatencyForNode.removeAll(keepingCapacity: true)
        }
    }
    
    // Update cached nodes list for a specific group
    func updateCachedNodesForGroup(_ group: ProxyGroup) {
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
    
    // Update cached latency values for a group when latencies change
    func updateCachedLatencyForGroup(_ group: ProxyGroup) {
        guard let nodes = cachedNodesForGroup[group.name] else { return }
        
        for node in nodes {
            let key = "\(group.name)-\(node)"
            let delayValue = appState.delayValue(group: group.name, node: node)
            let delayText = appState.delayText(group: group.name, node: node)
            cachedLatencyForNode[key] = (text: delayText, value: delayValue)
        }
    }
    
    // Throttled cache update to avoid excessive updates
    private func throttledCacheUpdate() {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastCacheUpdate)
        
        // Only update cache if at least 100ms have passed
        if timeSinceLastUpdate >= 0.1 {
            updateCachedProxyGroups()
            lastCacheUpdate = now
        }
    }
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

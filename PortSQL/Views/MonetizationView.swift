import StoreKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var purchaseStore: PurchaseStore

    var body: some View {
        List {
            Section("Plan") {
                HStack {
                    Label(purchaseStore.proStatusText, systemImage: purchaseStore.hasPro ? "crown.fill" : "bolt.horizontal.circle")
                    Spacer()
                    if purchaseStore.hasPro {
                        Text("Active")
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = purchaseStore.lastError, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Premium Features") {
                ForEach(PremiumFeature.allCases) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbolName)
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title)
                            Text(feature.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Upgrade") {
                UpgradePane(feature: .savedWorkspaces, compact: false)
            }
        }
        .navigationTitle("Settings")
    }
}

struct PaywallView: View {
    let feature: PremiumFeature

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: feature.symbolName)
                            .font(.system(size: 38))
                            .foregroundStyle(.yellow)
                        Text(feature.title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(feature.subtitle)
                            .foregroundStyle(.secondary)
                    }

                    UpgradePane(feature: feature, compact: false)
                }
                .padding()
            }
            .navigationTitle("PortSQL Pro")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct UpgradePane: View {
    @EnvironmentObject private var purchaseStore: PurchaseStore

    let feature: PremiumFeature
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text("Designed as optional add-ons")
                    .font(.headline)
                Text("Core database access remains usable on the free plan. Pro is for convenience and polish, not basic connectivity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(purchaseStore.products, id: \.id) { product in
                Button {
                    Task {
                        await purchaseStore.purchase(product)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.displayName)
                            Text(product.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(product.displayPrice)
                            .fontWeight(.semibold)
                    }
                    .padding()
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(purchaseStore.isLoading)
            }

            Button("Restore Purchases") {
                Task {
                    await purchaseStore.restorePurchases()
                }
            }
            .disabled(purchaseStore.isLoading)
        }
        .padding(compact ? 0 : 4)
        .task {
            if purchaseStore.products.isEmpty {
                await purchaseStore.refreshProducts()
            }
        }
    }
}

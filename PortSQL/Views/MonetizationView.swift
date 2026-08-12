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
                    Button {
                        purchaseStore.presentPaywall(for: feature)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: feature.symbolName)
                                .foregroundStyle(.orange)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .foregroundStyle(.primary)
                                Text(feature.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: purchaseStore.hasPro ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundStyle(purchaseStore.hasPro ? .green : .secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(purchaseStore.hasPro)
                    .accessibilityLabel(feature.title)
                    .accessibilityValue(purchaseStore.hasPro ? L10n.text("Unlocked") : L10n.text("Available with PortSQL Pro"))
                    .accessibilityHint(purchaseStore.hasPro ? "" : L10n.text("Opens purchase options"))
                }
            }

            Section("Upgrade") {
                UpgradePane(feature: .unlimitedBookmarks, compact: false)
            }
        }
        .navigationTitle("Settings")
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
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
                            .font(.title.weight(.bold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        Text(feature.subtitle)
                            .foregroundStyle(.secondary)
                    }

                    UpgradePane(feature: feature, compact: false)
                }
                .padding()
            }
            .navigationTitle("PortSQL Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
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

            if purchaseStore.isLoading && purchaseStore.products.isEmpty {
                ProgressView("Loading purchase options…")
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else if purchaseStore.products.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Purchase options unavailable", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        Text(purchaseStore.lastError ?? L10n.text("Check your network connection and try again."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task {
                            await purchaseStore.refreshProducts()
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
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
                        .frame(minHeight: 56)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(purchaseStore.isLoading)
                    .accessibilityLabel(L10n.format("Purchase %@, %@", product.displayName, product.displayPrice))
                    .accessibilityHint(L10n.text("Begins an App Store purchase"))
                }
            }

            Button {
                Task {
                    await purchaseStore.restorePurchases()
                }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(purchaseStore.isLoading)
            .accessibilityHint(L10n.text("Checks the App Store for previous PortSQL purchases"))
        }
        .padding(compact ? 0 : 4)
        .task {
            if purchaseStore.products.isEmpty {
                await purchaseStore.refreshProducts()
            }
        }
    }
}

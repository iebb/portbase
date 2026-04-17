import Foundation
import StoreKit

@MainActor
final class PurchaseStore: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var presentedFeature: PremiumFeature?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    var hasPro: Bool {
        !purchasedProductIDs.isEmpty
    }

    var proStatusText: String {
        hasPro ? "Pro unlocked" : "Free plan"
    }

    func configure() async {
        await refreshProducts()
        await refreshEntitlements()
    }

    func presentPaywall(for feature: PremiumFeature) {
        presentedFeature = feature
    }

    func refreshProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await Product.products(for: PurchaseCatalog.productIDs)
            products = fetched.sorted {
                PurchaseCatalog.sortIndex(for: $0.id) < PurchaseCatalog.sortIndex(for: $1.id)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                purchasedProductIDs.insert(transaction.productID)
                await transaction.finish()
                presentedFeature = nil
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if PurchaseCatalog.productIDs.contains(transaction.productID) {
                    purchased.insert(transaction.productID)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        purchasedProductIDs = purchased
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                do {
                    let transaction = try self.checkVerified(result)
                    await MainActor.run {
                        if PurchaseCatalog.productIDs.contains(transaction.productID) {
                            self.purchasedProductIDs.insert(transaction.productID)
                        }
                    }
                    await transaction.finish()
                } catch {
                    await MainActor.run {
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            safe
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

private enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            "App Store receipt verification failed."
        }
    }
}

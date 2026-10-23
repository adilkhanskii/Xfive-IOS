# X Five Credit Store Implementation Plan

1. Add failing catalog and routing tests for the three consumable packs, the 1,000 KZT verification subscription, hidden legacy subscriptions, and server-derived amounts.
2. Add a service-only, exact-once Apple consumable ledger/RPC and route verified App Store transactions by product kind. Cover replay and cross-user rejection.
3. Update iOS StoreKit catalog, unfinished-transaction recovery, Store/Profile UI, verified price, localization, and metadata while preserving legacy subscription restore.
4. Update Android web catalog, Store/Profile UI, verified screen, native Play product classification, and server entitlement mapping while preserving legacy subscription restore.
5. Configure App Store Connect consumables and verification pricing; prepare the exact Google Play product configuration when console credentials are unavailable.
6. Run focused tests, type checks, production web build, Edge tests, iOS CI, and review only the files changed for this feature.

//
//  ContentView.swift
//  nutridrop
//
//  Created by Aleksandr Diamond on 9/3/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme

    let authSession: AuthSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.04, green: 0.13, blue: 0.08), .black]
                    : [Color(red: 0.94, green: 0.97, blue: 0.91), .white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "drop.fill")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.45, blue: 0.27))
                    .symbolEffect(.breathe, options: .repeating)

                VStack(spacing: 8) {
                    Text("Nutridrop")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text(authSession.isAuthenticated ? "You're connected" : "Nutrition, delivered to Health")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let user = authSession.user {
                    signedInCard(userID: user.userId)
                    nutritionList
                } else {
                    signInCard
                }

                Spacer()
                Text("Authentication is securely provided by WorkOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            }
        }
        .alert(
            "Authentication Error",
            isPresented: Binding(
                get: { authSession.errorMessage != nil },
                set: { if !$0 { authSession.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { authSession.errorMessage = nil }
        } message: {
            Text(authSession.errorMessage ?? "Please try again.")
        }
        .task(id: authSession.isAuthenticated) {
            if authSession.isAuthenticated {
                await authSession.verifyBackendSession()
                if authSession.healthSyncEnabled {
                    _ = await authSession.syncPendingNutrition()
                }
            }
        }
    }

    private var signInCard: some View {
        Button(action: authSession.signIn) {
            HStack {
                if authSession.isLoading {
                    ProgressView()
                        .tint(.white)
                }
                Text(authSession.isLoading ? "Opening WorkOS..." : "Sign in")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.38, blue: 0.23), in: .rect(cornerRadius: 14))
        .disabled(authSession.isLoading)
    }

    private var nutritionList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Downloaded nutrition").font(.title2.bold())
            Text(authSession.healthStatus).font(.subheadline)
            Text("Enabling Apple Health writes all pending entries and future nutrition from this account. Existing Health data is not read or deleted.")
                .font(.caption).foregroundStyle(.secondary)
            Button(authSession.healthSyncEnabled ? "Review Health permissions" : "Enable Apple Health") {
                Task { await authSession.enableHealthKit() }
            }
            .disabled(authSession.healthAuthorizationInProgress)
            Button("Sync now") {
                Task { _ = await authSession.syncPendingNutrition() }
            }
            Text(authSession.nutritionSyncStatus).font(.caption).foregroundStyle(.secondary)
            if let date = authSession.lastNutritionSyncAt {
                Text("Last complete download: \(date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if authSession.nutritionRecords.isEmpty {
                Text("No nutrition downloaded yet. Record a meal through ChatGPT to trigger a push.")
                    .foregroundStyle(.secondary)
            }
            ForEach(authSession.nutritionRecords) { record in
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.mealLabel ?? "Nutrition entry").font(.headline)
                    Text(record.consumptionDescription).font(.subheadline).foregroundStyle(.secondary)
                    let state = authSession.healthStates[record.id] ?? HealthRecordState(stage: .downloaded)
                    Text(state.label)
                        .font(.caption.bold())
                        .foregroundStyle(state.stage == .synced ? Color.green : Color.secondary)
                    if let message = state.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(record.quantities.enumerated()), id: \.offset) { _, quantity in
                        HStack {
                            Text(quantity.nutrient.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer()
                            Text("\(quantity.value.formatted()) \(quantity.unit)").monospacedDigit()
                        }
                    }
                    Text(record.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: .rect(cornerRadius: 18))
            }
        }
    }

    private func signedInCard(userID: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)

            Text(userID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            backendConnectionStatus
            if let receivedAt = authSession.lastPushReceivedAt,
               let recordID = authSession.lastPushRecordID {
                VStack(spacing: 4) {
                    Text("Last push received").font(.caption.bold())
                    Text(receivedAt.formatted(date: .abbreviated, time: .standard))
                    Text(recordID).font(.caption2).textSelection(.enabled)
                    Text("Push receipt; Health sync status is shown per entry below.").font(.caption2)
                }
                .font(.caption)
            } else {
                Text("No push received yet").font(.caption).foregroundStyle(.secondary)
            }
            Text(authSession.pushRegistrationStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry push registration") {
                UIApplication.shared.registerForRemoteNotifications()
                authSession.uploadPushToken()
            }


            Button("Sign out", role: .destructive, action: authSession.signOut)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    private var backendConnectionStatus: some View {
        switch authSession.backendConnectionState {
        case .idle, .checking:
            Label("Checking backend connection...", systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.secondary)
        case .connected:
            Label("Backend connected", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .failed:
            VStack(spacing: 8) {
                Label("Backend connection failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let message = authSession.backendErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Retry") {
                    Task { await authSession.verifyBackendSession() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    ContentView(authSession: AuthSession())
}

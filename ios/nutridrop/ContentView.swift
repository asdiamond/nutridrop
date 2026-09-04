//
//  ContentView.swift
//  nutridrop
//
//  Created by Aleksandr Diamond on 9/3/26.
//

import SwiftUI
import WorkOS

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
                    signedInCard(name: user.name, email: user.email)
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
        .alert(
            "Couldn't Sign In",
            isPresented: Binding(
                get: { authSession.errorMessage != nil },
                set: { if !$0 { authSession.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { authSession.errorMessage = nil }
        } message: {
            Text(authSession.errorMessage ?? "Please try again.")
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

    private func signedInCard(name: String?, email: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)

            VStack(spacing: 4) {
                if let name, !name.isEmpty {
                    Text(name)
                        .font(.title3.bold())
                }
                Text(email)
                    .foregroundStyle(.secondary)
            }

            Button("Sign out", role: .destructive, action: authSession.signOut)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
    }
}

#Preview {
    ContentView(authSession: AuthSession())
}

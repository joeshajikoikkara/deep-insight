import SwiftUI

@main
struct GoogleSignInExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AuthViewModel: ObservableObject {
    @Published var isSignedIn = false
    @Published var userName: String? = nil

    func signInWithGoogle() async {
        guard let rootVC = await UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else { return }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            self.userName = result.user.profile?.name
            self.isSignedIn = true
        } catch {
            print("Google Sign-In failed: \(error)")
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        self.userName = nil
        self.isSignedIn = false
    }
}

struct ContentView: View {
    @StateObject private var authViewModel = AuthViewModel()

    var body: some View {
        VStack(spacing: 20) {
            if authViewModel.isSignedIn {
                Text("Hello, \(authViewModel.userName ?? "User")!")
                Button("Sign Out") {
                    authViewModel.signOut()
                }
            } else {
                Button("Sign In with Google") {
                    Task {
                        await authViewModel.signInWithGoogle()
                    }
                }
            }
        }
        .padding()
    }
}

import GoogleSignIn
import UIKit

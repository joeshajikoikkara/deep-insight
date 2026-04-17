//
//  ContentView.swift
//  Deep Insight
//
//  Created by Joe Shaji on 17/04/26.
//

import SwiftUI
import Combine
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// NOTE:
// - Add the GoogleSignIn Swift Package: https://github.com/google/GoogleSignIn-iOS
// - Configure your URL scheme with the reversed client ID from Google Cloud Console.
// - Include GoogleService-Info.plist in the app target.

// MARK: - Auth ViewModel
final class AuthViewModel: ObservableObject {
    private let userNameDefaultsKey = "Auth.UserName"
    private let userEmailDefaultsKey = "Auth.UserEmail"

    @Published var isSignedIn: Bool = false
    @Published var userName: String? = nil
    @Published var userEmail: String? = nil
    @Published var signInUnavailableReason: String? = nil

    init() {
        self.userName = UserDefaults.standard.string(forKey: userNameDefaultsKey)
        self.userEmail = UserDefaults.standard.string(forKey: userEmailDefaultsKey)
        Task { await restorePreviousSignIn() }
    }

    private func resolvedGoogleClientID() -> String? {
        if let plistClientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !plistClientID.isEmpty {
            return plistClientID
        }

        guard let configURL = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: configURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: Any],
              let clientID = dict["CLIENT_ID"] as? String,
              !clientID.isEmpty else {
            return nil
        }
        return clientID
    }

    @MainActor
    func signInWithGoogle() async {
        #if canImport(GoogleSignIn)
        guard let clientID = resolvedGoogleClientID() else {
            signInUnavailableReason = "Missing Google config. Add GIDClientID to Info.plist or include GoogleService-Info.plist in the app target."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        // Ensure GoogleSignIn package is added and URL scheme is configured.
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else {
            print("Google Sign-In: Could not find root view controller to present sign-in.")
            return
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            self.userEmail = result.user.profile?.email
            self.userName = result.user.profile?.name ?? result.user.profile?.email
            UserDefaults.standard.set(self.userName, forKey: userNameDefaultsKey)
            UserDefaults.standard.set(self.userEmail, forKey: userEmailDefaultsKey)
            self.isSignedIn = true
        } catch {
            print("Google Sign-In failed: \(error)")
        }
        #else
        // Fallback when the SDK is not available
        signInUnavailableReason = "GoogleSignIn SDK not found. Add the Swift Package to this target."
        #endif
    }

    @MainActor
    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        self.userName = nil
        self.userEmail = nil
        self.isSignedIn = false
        UserDefaults.standard.removeObject(forKey: userNameDefaultsKey)
        UserDefaults.standard.removeObject(forKey: userEmailDefaultsKey)
    }

    @MainActor
    func restorePreviousSignIn() async {
        #if canImport(GoogleSignIn)
        guard let clientID = resolvedGoogleClientID() else {
            self.isSignedIn = false
            signInUnavailableReason = "Missing Google config. Add GIDClientID to Info.plist or include GoogleService-Info.plist in the app target."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            self.userEmail = user.profile?.email
            self.userName = user.profile?.name ?? user.profile?.email
            self.isSignedIn = true
            UserDefaults.standard.set(self.userName, forKey: userNameDefaultsKey)
            UserDefaults.standard.set(self.userEmail, forKey: userEmailDefaultsKey)
        } catch {
            self.isSignedIn = false
        }
        #else
        // Without the SDK, we can't restore; keep signed out and inform.
        self.isSignedIn = false
        if signInUnavailableReason == nil {
            signInUnavailableReason = "GoogleSignIn SDK not found. Add the Swift Package to this target."
        }
        #endif
    }
}

// MARK: - ContentView (Auth-aware container)
struct ContentView: View {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var resultsPreferences = ResultsPreferences()

    var body: some View {
        Group {
            if auth.isSignedIn {
                DashboardView()
                    .environmentObject(auth)
                    .environmentObject(resultsPreferences)
            } else {
                SignInView()
                    .environmentObject(auth)
            }
        }
        .task { await auth.restorePreviousSignIn() }
    }
}

// MARK: - Sign In Screen
struct SignInView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 64, weight: .semibold))
            Text("Welcome to Deep Insight")
                .font(.title2).bold()
            Text("Sign in to continue")
                .foregroundStyle(.secondary)

            if let reason = auth.signInUnavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: { Task { await signIn() } }) {
                HStack(spacing: 12) {
                    Image(systemName: "g.circle")
                        .font(.title2)
                    Text(isSigningIn ? "Signing in…" : "Sign in with Google")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isSigningIn || auth.signInUnavailableReason != nil)
            .padding(.horizontal)

            Spacer()
            Text("By continuing you agree to our Terms and Privacy Policy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func signIn() async {
        isSigningIn = true
        await auth.signInWithGoogle()
        isSigningIn = false
    }
}

// MARK: - Dashboard (Home + Settings)
struct DashboardView: View {
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        TabView {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }

            NavigationStack {
                HomeView()
                    .navigationTitle("Home")
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                ClasswiseListView()
                    .navigationTitle("Classwise")
            }
            .tabItem {
                Label("Classwise", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

// MARK: - Home
struct HomeView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var resultsPreferences: ResultsPreferences
    @StateObject private var dashboardVM = ResultsDashboardViewModel(examId: 202601)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let name = auth.userName {
                    Text("Hello, \(name)!")
                        .font(.title2).bold()
                } else {
                    Text("Hello!")
                        .font(.title2).bold()
                }

                if dashboardVM.isLoading && dashboardVM.data == nil {
                    ProgressView("Loading results dashboard…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = dashboardVM.errorMessage, dashboardVM.data == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await dashboardVM.loadDashboard() }
                        }
                    }
                }

                if let dashboardData = dashboardVM.data {
                    ResultsDashboardSection(dashboardData: dashboardData)
                }
            }
            .padding()
        }
        .task {
            dashboardVM.updateExamId(resultsPreferences.selectedExamId)
            await dashboardVM.loadDashboard(force: true)
        }
        .onChange(of: resultsPreferences.selectedExamId) {
            dashboardVM.updateExamId(resultsPreferences.selectedExamId)
            Task { await dashboardVM.loadDashboard(force: true) }
        }
        .refreshable { await dashboardVM.loadDashboard(force: true) }
    }
}

struct ClasswiseListView: View {
    private let classes: [ClassListItem] = [
        ClassListItem(classId: 301, examId: 202601, title: "CS-A (Semester 1)", subtitle: "End Semester • Apr 2026"),
        ClassListItem(classId: 302, examId: 202601, title: "CS-B (Semester 1)", subtitle: "End Semester • Apr 2026"),
        ClassListItem(classId: 303, examId: 202601, title: "CS-C (Semester 1)", subtitle: "End Semester • Apr 2026")
    ]

    var body: some View {
        List(classes) { item in
            NavigationLink {
                ClassAnalyticsView(item: item)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).fontWeight(.semibold)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ClassAnalyticsView: View {
    let item: ClassListItem
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var resultsPreferences: ResultsPreferences
    @StateObject private var dashboardVM: ResultsDashboardViewModel
    @State private var showInsightSummary = false
    private let insightSectionId = "class-insight-summary-section"

    init(item: ClassListItem) {
        self.item = item
        _dashboardVM = StateObject(
            wrappedValue: ResultsDashboardViewModel(classId: item.classId, examId: item.examId)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.title3)
                                .fontWeight(.bold)
                            Text(item.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            showInsightSummary = true
                            withAnimation {
                                proxy.scrollTo(insightSectionId, anchor: .top)
                            }
                            Task {
                                await dashboardVM.loadInsightSummary(
                                    userEmail: auth.userEmail,
                                    force: true
                                )
                                withAnimation {
                                    proxy.scrollTo(insightSectionId, anchor: .top)
                                }
                            }
                        } label: {
                            Label("Insight", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel("Generate Insight")
                        .disabled(dashboardVM.isInsightLoading)
                    }

                    if dashboardVM.isLoading && dashboardVM.data == nil {
                        ProgressView("Loading analytics…")
                    } else if let error = dashboardVM.errorMessage, dashboardVM.data == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await dashboardVM.loadDashboard() }
                            }
                        }
                    }

                    if let dashboardData = dashboardVM.data {
                        ResultsDashboardSection(dashboardData: dashboardData)
                    }

                    if showInsightSummary {
                        InsightSummarySection(
                            isLoading: dashboardVM.isInsightLoading,
                            isSubmitting: dashboardVM.isActionPointSubmitting,
                            summary: dashboardVM.insightSummary,
                            actionPoint: dashboardVM.actionPoint,
                            editedActionPoint: $dashboardVM.editedActionPoint,
                            isEditingActionPoint: $dashboardVM.isEditingActionPoint,
                            canEditActionPoint: dashboardVM.canEditActionPoint,
                            errorMessage: dashboardVM.insightErrorMessage,
                            submitFeedbackMessage: dashboardVM.submitFeedbackMessage,
                            submitFeedbackIsError: dashboardVM.submitFeedbackIsError
                        ) {
                            Task {
                                await dashboardVM.submitActionPoint(userEmail: auth.userEmail)
                            }
                        }
                        .id(insightSectionId)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Analytics")
        .task {
            dashboardVM.updateExamId(resultsPreferences.selectedExamId)
            await dashboardVM.loadDashboard(force: true)
        }
        .onChange(of: resultsPreferences.selectedExamId) {
            dashboardVM.updateExamId(resultsPreferences.selectedExamId)
            showInsightSummary = false
            Task { await dashboardVM.loadDashboard(force: true) }
        }
        .refreshable { await dashboardVM.loadDashboard(force: true) }
    }
}

struct ClassListItem: Identifiable {
    let id = UUID()
    let classId: Int
    let examId: Int
    let title: String
    let subtitle: String
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ResultsDashboardSection: View {
    let dashboardData: ResultsDashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(dashboardData.courseName)")
                .foregroundStyle(.secondary)
            Text("Class \(dashboardData.className) • Exam \(dashboardData.examName)")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                DashboardMetricCard(
                    title: "Students",
                    value: "\(dashboardData.totalStudents)",
                    subtitle: "Appeared"
                )
                DashboardMetricCard(
                    title: "Pass %",
                    value: String(format: "%.1f%%", dashboardData.passPercentage),
                    subtitle: "\(dashboardData.passedStudents) passed"
                )
            }

            HStack(spacing: 12) {
                DashboardMetricCard(
                    title: "Avg GPA",
                    value: String(format: "%.2f", dashboardData.averageGPA),
                    subtitle: "Class average"
                )
                DashboardMetricCard(
                    title: "Top GPA",
                    value: String(format: "%.2f", dashboardData.topGPA),
                    subtitle: dashboardData.toppers.first?.name ?? "-"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Top Performers")
                    .font(.headline)
                ForEach(dashboardData.toppers) { student in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(student.name).fontWeight(.semibold)
                            Text(student.registerNo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.2f", student.gpa))
                            .fontWeight(.bold)
                    }
                    .padding(12)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Subject-wise Average")
                    .font(.headline)
                ForEach(dashboardData.subjectAverages) { subject in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(subject.subjectName).font(.subheadline)
                            Spacer()
                            Text("\(subject.averageMark, specifier: "%.1f") / 100")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: subject.averageMark, total: 100)
                            .tint(subject.averageMark >= 80 ? .green : (subject.averageMark >= 65 ? .orange : .red))
                    }
                }
            }
        }
    }
}

private struct InsightSummarySection: View {
    let isLoading: Bool
    let isSubmitting: Bool
    let summary: String?
    let actionPoint: String?
    @Binding var editedActionPoint: String
    @Binding var isEditingActionPoint: Bool
    let canEditActionPoint: Bool
    let errorMessage: String?
    let submitFeedbackMessage: String?
    let submitFeedbackIsError: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                Text("AI Insight")
                    .font(.headline)
            }

            if isLoading {
                ProgressView("Generating summary…")
            } else if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("Tap the insight button to generate a summary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Action Point")
                    .font(.headline)
                Spacer()
                if canEditActionPoint && !isEditingActionPoint {
                    Button {
                        editedActionPoint = actionPoint ?? ""
                        isEditingActionPoint = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline)
                            .padding(8)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Edit Action Point")
                }
            }

            if canEditActionPoint {
                if isEditingActionPoint {
                    TextEditor(text: $editedActionPoint)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: onSubmit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Submit Action Point")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isSubmitting || isLoading)
                } else {
                    Text((actionPoint?.isEmpty == false) ? actionPoint! : "No action point submitted yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text((actionPoint?.isEmpty == false) ? actionPoint! : "No action point submitted yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let submitFeedbackMessage, !submitFeedbackMessage.isEmpty {
                Text(submitFeedbackMessage)
                    .font(.footnote)
                    .foregroundStyle(submitFeedbackIsError ? .red : .green)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct DashboardTopper: Identifiable {
    let id = UUID()
    let name: String
    let registerNo: String
    let gpa: Double
}

struct DashboardSubjectAverage: Identifiable {
    let id = UUID()
    let subjectName: String
    let averageMark: Double
}

struct ResultsDashboardData {
    let courseName: String
    let className: String
    let examName: String
    let totalStudents: Int
    let passedStudents: Int
    let averageGPA: Double
    let topGPA: Double
    let toppers: [DashboardTopper]
    let subjectAverages: [DashboardSubjectAverage]

    var passPercentage: Double {
        guard totalStudents > 0 else { return 0 }
        return (Double(passedStudents) / Double(totalStudents)) * 100
    }
}

private struct ResultsDashboardResponse: Decodable {
    let courseName: String
    let className: String
    let examName: String
    let totalStudents: Int
    let passedStudents: Int
    let averageGPA: Double
    let topGPA: Double
    let toppers: [Topper]
    let subjectAverages: [SubjectAverage]

    struct Topper: Decodable {
        let name: String
        let registerNo: String
        let gpa: Double
    }

    struct SubjectAverage: Decodable {
        let subjectName: String
        let averageMark: Double
    }
}

private struct InsightSummaryResponse: Decodable {
    let summary: String
    let actionPoint: String?
    let canEditActionPoint: Bool?
}

private struct APIErrorResponse: Decodable {
    let message: String?
}

@MainActor
final class ResultsDashboardViewModel: ObservableObject {
    @Published var data: ResultsDashboardData?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var insightSummary: String?
    @Published var isInsightLoading: Bool = false
    @Published var insightErrorMessage: String?
    @Published var actionPoint: String?
    @Published var editedActionPoint: String = ""
    @Published var canEditActionPoint: Bool = false
    @Published var isActionPointSubmitting: Bool = false
    @Published var isEditingActionPoint: Bool = false
    @Published var submitFeedbackMessage: String?
    @Published var submitFeedbackIsError: Bool = false

    private let classId: Int
    private var examId: Int
    private let baseURL = "http://43.204.234.183/deep-insight"

    init(classId: Int = 301, examId: Int = 202601) {
        self.classId = classId
        self.examId = examId
    }

    func updateExamId(_ examId: Int) {
        self.examId = examId
        self.insightSummary = nil
        self.insightErrorMessage = nil
        self.actionPoint = nil
        self.editedActionPoint = ""
        self.canEditActionPoint = false
        self.isActionPointSubmitting = false
        self.isEditingActionPoint = false
        self.submitFeedbackMessage = nil
        self.submitFeedbackIsError = false
    }

    func loadDashboard(force: Bool = false) async {
        if isLoading { return }
        if data != nil && !force { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard var components = URLComponents(string: "\(baseURL)/api/results/dashboard") else {
                throw URLError(.badURL)
            }
            components.queryItems = [
                URLQueryItem(name: "classId", value: String(classId)),
                URLQueryItem(name: "examId", value: String(examId))
            ]
            guard let url = components.url else {
                throw URLError(.badURL)
            }

            let (payload, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let decoded = try JSONDecoder().decode(ResultsDashboardResponse.self, from: payload)
            data = ResultsDashboardData(
                courseName: decoded.courseName,
                className: decoded.className,
                examName: decoded.examName,
                totalStudents: decoded.totalStudents,
                passedStudents: decoded.passedStudents,
                averageGPA: decoded.averageGPA,
                topGPA: decoded.topGPA,
                toppers: decoded.toppers.map { DashboardTopper(name: $0.name, registerNo: $0.registerNo, gpa: $0.gpa) },
                subjectAverages: decoded.subjectAverages.map { DashboardSubjectAverage(subjectName: $0.subjectName, averageMark: $0.averageMark) }
            )
        } catch {
            errorMessage = "Could not load dashboard data."
        }
    }

    func loadInsightSummary(userEmail: String?, force: Bool = false) async {
        if isInsightLoading { return }
        if insightSummary != nil && !force { return }

        isInsightLoading = true
        insightErrorMessage = nil
        submitFeedbackMessage = nil
        defer { isInsightLoading = false }

        do {
            guard var components = URLComponents(string: "\(baseURL)/api/results/insight-summary") else {
                throw URLError(.badURL)
            }
            components.queryItems = [
                URLQueryItem(name: "classId", value: String(classId)),
                URLQueryItem(name: "examId", value: String(examId)),
                URLQueryItem(name: "userEmail", value: userEmail)
            ]
            guard let url = components.url else {
                throw URLError(.badURL)
            }

            let (payload, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let backendError = try? JSONDecoder().decode(APIErrorResponse.self, from: payload)
                if httpResponse.statusCode == 404 {
                    insightErrorMessage = "Insight API is not deployed on backend (404)."
                    return
                }
                if let message = backendError?.message, !message.isEmpty {
                    insightErrorMessage = "Insight generation failed: \(message)"
                    return
                }
                insightErrorMessage = "Insight generation failed with status \(httpResponse.statusCode)."
                return
            }

            let decoded = try JSONDecoder().decode(InsightSummaryResponse.self, from: payload)
            insightSummary = decoded.summary
            actionPoint = decoded.actionPoint ?? ""
            editedActionPoint = decoded.actionPoint ?? ""
            canEditActionPoint = decoded.canEditActionPoint ?? false
            isEditingActionPoint = (decoded.actionPoint ?? "").isEmpty
        } catch {
            insightErrorMessage = "Could not generate insight summary."
        }
    }

    func submitActionPoint(userEmail: String?) async {
        if isActionPointSubmitting { return }
        if !canEditActionPoint {
            insightErrorMessage = "You do not have permission to edit action points."
            return
        }
        if (userEmail ?? "").isEmpty {
            insightErrorMessage = "Missing user email for action point submission."
            return
        }

        isActionPointSubmitting = true
        insightErrorMessage = nil
        submitFeedbackMessage = nil
        defer { isActionPointSubmitting = false }

        do {
            guard let url = URL(string: "\(baseURL)/api/results/action-point") else {
                throw URLError(.badURL)
            }

            let body: [String: Any] = [
                "classId": classId,
                "examId": examId,
                "actionPoint": editedActionPoint,
                "userEmail": userEmail ?? ""
            ]

            let payload = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            let (responsePayload, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let backendError = try? JSONDecoder().decode(APIErrorResponse.self, from: responsePayload)
                if let message = backendError?.message, !message.isEmpty {
                    insightErrorMessage = message
                } else {
                    insightErrorMessage = "Could not submit action point."
                }
                submitFeedbackMessage = insightErrorMessage
                submitFeedbackIsError = true
                return
            }

            actionPoint = editedActionPoint
            isEditingActionPoint = false
            submitFeedbackMessage = "Action point submitted successfully."
            submitFeedbackIsError = false
        } catch {
            insightErrorMessage = "Could not submit action point."
            submitFeedbackMessage = insightErrorMessage
            submitFeedbackIsError = true
        }
    }
}

final class ResultsPreferences: ObservableObject {
    @AppStorage("Results.SelectedAcademicYear") var selectedAcademicYear: Int = 2026
    @AppStorage("Results.SelectedExamId") var selectedExamId: Int = 202601

    let academicYears: [Int] = [2025, 2026, 2027]
    let exams: [ExamOption] = [
        ExamOption(id: 202501, year: 2025, name: "Mid Semester"),
        ExamOption(id: 202502, year: 2025, name: "End Semester"),
        ExamOption(id: 202601, year: 2026, name: "Mid Semester"),
        ExamOption(id: 202602, year: 2026, name: "End Semester"),
        ExamOption(id: 202701, year: 2027, name: "Mid Semester"),
        ExamOption(id: 202702, year: 2027, name: "End Semester")
    ]

    var examsForSelectedYear: [ExamOption] {
        exams.filter { $0.year == selectedAcademicYear }
    }

    func normalizeExamSelection() {
        if !examsForSelectedYear.contains(where: { $0.id == selectedExamId }) {
            selectedExamId = examsForSelectedYear.first?.id ?? selectedExamId
        }
    }
}

struct ExamOption: Identifiable, Hashable {
    let id: Int
    let year: Int
    let name: String
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var resultsPreferences: ResultsPreferences

    var body: some View {
        List {
            Section(header: Text("Account")) {
                HStack {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading) {
                        Text(auth.userName ?? "Signed in")
                        Text("Google Account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section(header: Text("Results Filter")) {
                Picker("Academic Year", selection: $resultsPreferences.selectedAcademicYear) {
                    ForEach(resultsPreferences.academicYears, id: \.self) { year in
                        Text("\(year)").tag(year)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: resultsPreferences.selectedAcademicYear) {
                    resultsPreferences.normalizeExamSelection()
                }

                Picker("Exam", selection: $resultsPreferences.selectedExamId) {
                    ForEach(resultsPreferences.examsForSelectedYear) { exam in
                        Text("\(exam.name) \(exam.year)").tag(exam.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(header: Text("About")) {
                HStack {
                    Text("App")
                    Spacer()
                    Text("Deep Insight")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

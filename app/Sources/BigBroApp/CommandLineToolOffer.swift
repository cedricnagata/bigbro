import BigBroControl
import SwiftUI

/// Offers the CLI once, on first launch.
///
/// The install has existed since the app did, buried in Settings › Command line,
/// and being buried was most of the problem: a button nobody finds is close to a
/// button that is not there. Docker asks during setup for the same reason.
///
/// Asked once and never again, whatever the answer. Someone who declines can still
/// install from Settings, and a prompt that returns every launch to re-ask a
/// question already answered is worse than not asking.
@MainActor
private struct CommandLineToolOffer: ViewModifier {
    @AppStorage("hasOfferedCommandLineTool") private var hasOffered = false
    @State private var isPresented = false
    @State private var problem: String?

    /// A stored constant rather than literals joined with `+` inside `Text`. A long
    /// concatenation chain is one expression to the type checker, and the release
    /// runner's compiler gives up on it: "unable to type-check this expression in
    /// reasonable time". Newer ones manage, which makes it another thing that builds
    /// locally and fails on CI.
    private static let explanation = """
        Adds a `bigbro` command that drives this same daemon — `bigbro status`, \
        `bigbro pair approve`, `bigbro models list`.

        All terminals installs to /usr/local/bin and asks for your password once. \
        Just for me uses ~/.local/bin, which needs no password but is not on the \
        default PATH.

        You can change this later in Settings.
        """

    func body(content: Content) -> some View {
        content
            .task {
                // Nothing to offer in a `swift run` build, and nothing to ask
                // someone who installed it from a previous launch.
                guard !hasOffered,
                      CommandLineTool.bundledInterpreter() != nil,
                      !CommandLineTool.isInstalled()
                else { return }
                isPresented = true
            }
            .alert("Install the `bigbro` command?", isPresented: $isPresented) {
                Button("Install for All Terminals…") { install(into: .allTerminals) }
                Button("Just for Me") { install(into: .thisUser) }
                Button("Not Now", role: .cancel) { hasOffered = true }
            } message: {
                Text(Self.explanation)
            }
            .alert("Could not install", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: {
                Text(problem ?? "")
            }
    }

    private func install(into scope: CommandLineTool.Scope) {
        do {
            try CommandLineTool.install(into: scope)
            hasOffered = true
        } catch CommandLineTool.Failure.cancelled {
            // Dismissing the password prompt is a "not now", not a refusal of the
            // question — leave the offer standing for next launch.
        } catch {
            problem = error.localizedDescription
            hasOffered = true
        }
    }
}

extension View {
    // Isolated because the modifier is: its `@AppStorage` and `@State` defaults make
    // the memberwise init main-actor-isolated, and constructing it from a nonisolated
    // context is exactly the kind of thing that builds on one compiler and not another.
    @MainActor
    func commandLineToolOffer() -> some View { modifier(CommandLineToolOffer()) }
}

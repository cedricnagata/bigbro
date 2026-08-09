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
private struct CommandLineToolOffer: ViewModifier {
    @AppStorage("hasOfferedCommandLineTool") private var hasOffered = false
    @State private var isPresented = false
    @State private var problem: String?

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
                Text("Adds a `bigbro` command that drives this same daemon — "
                     + "`bigbro status`, `bigbro pair approve`, `bigbro models list`.\n\n"
                     + "All terminals installs to /usr/local/bin and asks for your password "
                     + "once. Just for me uses ~/.local/bin, which needs no password but is "
                     + "not on the default PATH.\n\n"
                     + "You can change this later in Settings.")
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
    func commandLineToolOffer() -> some View { modifier(CommandLineToolOffer()) }
}

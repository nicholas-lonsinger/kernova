import SwiftUI

/// Root view wrapping `NavigationSplitView` with sidebar and detail columns.
struct ContentView: View {
    @Bindable var viewModel: VMLibraryViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel, isSidebarVisible: columnVisibility != .detailOnly)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 350)
        } detail: {
            if let selected = viewModel.selectedInstance {
                VMDetailView(instance: selected, viewModel: viewModel)
            } else {
                ContentUnavailableView {
                    Label("No Virtual Machine Selected", systemImage: "desktopcomputer")
                } description: {
                    Text("Select a virtual machine from the sidebar or create a new one.")
                } actions: {
                    Button("New Virtual Machine") {
                        viewModel.showCreationWizard = true
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    playButton
                    pauseButton
                    stopMenu
                }
                ControlGroup {
                    saveStateButton
                }
                ControlGroup {
                    fullscreenButton
                }
            }
        }
        .sheet(isPresented: $viewModel.showCreationWizard) {
            VMCreationWizardView(viewModel: viewModel)
        }
        .alert(
            "Error",
            isPresented: $viewModel.showError,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Toolbar Helpers

    /// Whether all toolbar buttons should be disabled (no VM selected or VM is preparing).
    private var allDisabled: Bool {
        guard let instance = viewModel.selectedInstance else { return true }
        return instance.isPreparing
    }

    // MARK: - Action Buttons

    private var playButton: some View {
        let canResume = viewModel.selectedInstance?.status.canResume ?? false

        return Button {
            if canResume {
                NSApp.sendAction(#selector(AppDelegate.resumeVM(_:)), to: nil, from: nil)
            } else {
                NSApp.sendAction(#selector(AppDelegate.startVM(_:)), to: nil, from: nil)
            }
        } label: {
            Label(canResume ? "Resume" : "Start", systemImage: "play.fill")
        }
        .disabled(allDisabled || !((viewModel.selectedInstance?.status.canStart ?? false) || canResume))
        .help(canResume ? "Resume the virtual machine" : "Start this virtual machine")
    }

    private var pauseButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.pauseVM(_:)), to: nil, from: nil)
        } label: {
            Label("Pause", systemImage: "pause.fill")
        }
        .disabled(allDisabled || !(viewModel.selectedInstance?.status.canPause ?? false))
        .help("Pause the virtual machine")
    }

    private var stopMenu: some View {
        Menu {
            Button("Force Stop") {
                NSApp.sendAction(#selector(AppDelegate.forceStopVM(_:)), to: nil, from: nil)
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
        } primaryAction: {
            NSApp.sendAction(#selector(AppDelegate.stopVM(_:)), to: nil, from: nil)
        }
        .disabled(allDisabled || !(viewModel.selectedInstance?.status.canStop ?? false))
        .menuIndicator(.hidden)
        .help("Stop the virtual machine. Click and hold for Force Stop.")
    }

    private var saveStateButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.saveVM(_:)), to: nil, from: nil)
        } label: {
            Label("Save State", systemImage: "square.and.arrow.down")
        }
        .disabled(allDisabled || !(viewModel.selectedInstance?.canSave ?? false))
        .help("Save the virtual machine state to disk")
    }

    private var fullscreenButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.toggleFullscreenDisplay(_:)), to: nil, from: nil)
        } label: {
            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .disabled(allDisabled || !(viewModel.selectedInstance?.canFullscreen ?? false))
        .help("Enter fullscreen display")
    }
}

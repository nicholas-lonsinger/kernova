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
                if let instance = viewModel.selectedInstance, !instance.isPreparing {
                    actionButtons(for: instance)
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

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for instance: VMInstance) -> some View {
        switch instance.status {
        case .stopped, .error:
            ControlGroup {
                startButton
            }
        case .running:
            ControlGroup {
                pauseButton
                stopMenu(for: instance)
            }
            ControlGroup {
                saveStateButton
            }
            ControlGroup {
                fullscreenButton
            }
        case .paused:
            ControlGroup {
                resumeButton
                stopMenu(for: instance)
            }
            if !instance.isColdPaused {
                ControlGroup {
                    saveStateButton
                }
                ControlGroup {
                    fullscreenButton
                }
            }
        case .starting, .saving, .restoring, .installing:
            EmptyView()
        }
    }

    private var startButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.startVM(_:)), to: nil, from: nil)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .help("Start this virtual machine")
    }

    private var pauseButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.pauseVM(_:)), to: nil, from: nil)
        } label: {
            Label("Pause", systemImage: "pause.fill")
        }
        .help("Pause the virtual machine")
    }

    private var resumeButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.resumeVM(_:)), to: nil, from: nil)
        } label: {
            Label("Resume", systemImage: "play.fill")
        }
        .help("Resume the virtual machine")
    }

    private func stopMenu(for instance: VMInstance) -> some View {
        Menu {
            Button("Force Stop") {
                NSApp.sendAction(#selector(AppDelegate.forceStopVM(_:)), to: nil, from: nil)
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
        } primaryAction: {
            NSApp.sendAction(#selector(AppDelegate.stopVM(_:)), to: nil, from: nil)
        }
        .menuIndicator(.hidden)
        .help("Stop the virtual machine. Click and hold for Force Stop.")
    }

    private var saveStateButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.saveVM(_:)), to: nil, from: nil)
        } label: {
            Label("Save State", systemImage: "square.and.arrow.down")
        }
        .help("Save the virtual machine state to disk")
    }

    private var fullscreenButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.toggleFullscreenDisplay(_:)), to: nil, from: nil)
        } label: {
            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .help("Enter fullscreen display")
    }
}

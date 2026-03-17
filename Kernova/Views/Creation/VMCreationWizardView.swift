import SwiftUI

/// Multi-step sheet for creating a new virtual machine.
struct VMCreationWizardView: View {
    @Bindable var viewModel: VMLibraryViewModel
    @State private var creationVM = VMCreationViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding()

            Divider()

            // Step content
            Group {
                switch creationVM.currentStep {
                case .osSelection:
                    OSSelectionStep(creationVM: creationVM)
                case .bootConfig:
                    if creationVM.selectedOS == .macOS {
                        IPSWSelectionStep(creationVM: creationVM)
                    } else {
                        BootConfigStep(creationVM: creationVM)
                    }
                case .resources:
                    ResourceConfigStep(creationVM: creationVM)
                case .review:
                    ReviewStep(creationVM: creationVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Divider()

            // Navigation buttons
            navigationButtons
                .padding()
        }
        .frame(width: 550, height: 480)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(VMCreationStep.allCases) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step == creationVM.currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)

                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(step == creationVM.currentStep ? .primary : .secondary)
                }

                if step != VMCreationStep.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: 30)
                }
            }
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let message = creationVM.validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if creationVM.currentStep != .osSelection {
                Button("Back") {
                    creationVM.goBack()
                }
            }

            if creationVM.currentStep == .review {
                Button("Create") {
                    Task {
                        await viewModel.createVM(from: creationVM)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!creationVM.canCreate)
            } else {
                Button("Next") {
                    creationVM.goNext()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!creationVM.canAdvance)
            }
        }
    }
}

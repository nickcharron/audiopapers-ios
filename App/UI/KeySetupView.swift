import AudiopapersKit
import SwiftUI
import UIKit

private let aiStudioKeysUrl = URL(string: "https://aistudio.google.com/apikey")!

/// First-run setup for the user's own Gemini key, also reachable later from Home.
struct KeySetupView: View {
    let onDone: () -> Void
    @State private var model = KeySetupModel()
    @State private var key = ""
    @State private var showKey = false
    @State private var modelName = ""
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set up Gemini").font(.title2.bold())
                Text("Audiopapers uses Google's Gemini to read new papers, describe figures and answer your questions. It's free with your own key, needs no credit card, and takes about two minutes.")

                step(1, "Open Google AI Studio and sign in with your Google account.")
                Link("Open Google AI Studio", destination: aiStudioKeysUrl).buttonStyle(.bordered)

                step(2, "Accept the terms if asked, then tap \"Create API key\". If a key is already listed, you can use that one.")
                step(3, "Copy the key, come back here, and paste it below.")

                HStack(spacing: 8) {
                    Group {
                        let label = model.hasKey ? "New key (blank keeps the saved one)" : "Gemini API key"
                        if showKey {
                            TextField(label, text: $key)
                        } else {
                            SecureField(label, text: $key)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button("Paste") {
                        if let pasted = UIPasteboard.general.string {
                            key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                Button(showKey ? "Hide key" : "Show key") { showKey.toggle() }

                if showAdvanced {
                    TextField("Model (blank = gemini-flash-latest)", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Button("Advanced: choose a model") { showAdvanced = true }
                }

                Button { model.saveAndCheck(key: key, model: modelName) } label: {
                    Text("Save and check").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .checking)

                switch model.state {
                case .checking:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking the key with Gemini...")
                    }
                case .saved:
                    Text("Your key works. You're ready to add papers.").foregroundStyle(Color.accentColor)
                    Button(action: onDone) { Text("Done").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }

                Text("Good to know").font(.subheadline.bold()).padding(.top, 8)
                Text("Your key stays on this phone, encrypted, and is only sent to Google.\n\nThe free tier allows a few requests per minute and a daily limit that resets at midnight Pacific time. Adding a paper uses a few requests; describing a figure or asking a question uses one. Listening to papers you've added uses none, and works offline.\n\nOn the free tier, Google may use what you send (the papers you add and your questions) to improve its products.")
                    .font(.caption)

                if model.hasKey {
                    Button("Remove saved key", role: .destructive) { model.removeKey() }
                }
            }
            .padding(24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            modelName = model.savedModel
            showAdvanced = !model.savedModel.isEmpty
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).").bold()
            Text(text)
        }
    }
}

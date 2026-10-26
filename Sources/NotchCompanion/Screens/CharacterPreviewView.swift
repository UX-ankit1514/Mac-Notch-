import AppKit
import NotchCore
import SwiftUI

/// Character Preview (PRD §15.3): all nine emotions, test notifications,
/// motion intensity and sound.
struct CharacterPreviewView: View {
    let model: AppModel
    @LocalState private var selected: Emotion = .anxiety
    @LocalState private var stage = CharacterController()

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Character Preview",
                             subtitle: "Each state has its own pose and motion. Click one to play it.")
                VStack(alignment: .leading, spacing: 8) {
                    NotchCard(height: 180) { CharacterView(controller: stage) }
                    Text("\(selected.displayName) — \(selected.meaning)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(Emotion.nine, id: \.self) { emotion in
                        Button { play(emotion) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                NotchCard(height: 64) { StillCharacter(emotion: emotion) }
                                Text(emotion.displayName).font(.headline)
                                Text(emotion.meaning).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected == emotion ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(emotion.displayName): \(emotion.meaning)")
                    }
                }

                HStack(spacing: 12) {
                    Button("Show in the notch") { sendToNotch(selected) }
                    Button("Two agents waiting") {
                        model.simulate(.permission, agent: .claudeCode, project: "Portfolio Website")
                        model.simulate(.question, agent: .codex, project: "Dashboard Redesign")
                    }
                    Button("Clear notch") { model.dismissAll() }
                    Spacer()
                    Button("Test sound") { NSSound(named: "Tink")?.play() }
                }

                Form {
                    Picker("Motion intensity", selection: $model.settings.motionIntensity) {
                        ForEach(MotionIntensity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Reduce motion (cross-fades only)", isOn: $model.settings.reduceMotion)
                }
                .formStyle(.grouped)
                .onChange(of: model.settings) { applySettings(); play(selected) }

                Text("About the motion: the character is a 2.5D rig built from the Figma renders. Pupils, eyelids, hands and effects are separate layers; mouths and brows are part of each authored pose. Higher-fidelity clips can replace any emotion without code changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
        .onAppear {
            applySettings()
            play(selected)
        }
    }

    private func applySettings() {
        stage.apply(intensity: model.settings.motionIntensity.scale, reduceMotion: model.reduceMotion)
    }

    private func play(_ emotion: Emotion) {
        selected = emotion
        let director = stage.director
        if director.machine.isVisible && director.machine.emotion == emotion {
            director.hide()
            Task {
                try? await Task.sleep(for: .milliseconds(320))
                director.show(emotion)
            }
        } else {
            director.show(emotion)
        }
    }

    private func sendToNotch(_ emotion: Emotion) {
        if emotion == .envy {
            model.simulate(.permission, agent: .claudeCode, project: "Portfolio Website")
            model.simulate(.permission, agent: .codex, project: "Dashboard Redesign")
            return
        }
        let type = EventType.allCases.first { EmotionEngine.emotion(for: $0) == emotion } ?? .completed
        model.simulate(type)
    }
}

import AVFoundation
#if SWIFT_PACKAGE
import CalciCredentials
#endif
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var text = ""
    @State private var key = ""
    @State private var saved = APIKeyStore.read() != nil
    @State private var keyError = false
    @State private var keyboardHand = KeyboardHand.read()
    @State private var layoutError = false

    @State private var provider = APIKeyStore.read("Calci.Provider") ?? "OpenAI"

    var body: some View {
        Form {
            Section {
                LabeledContent("麦克风", value: microphoneStatus)
                if microphone == .undetermined {
                    Button("允许使用麦克风", action: requestMicrophone)
                } else if microphone == .denied {
                    Button("在设置中允许麦克风", action: openSettings)
                }
            } header: {
                stepTitle("1. 权限")
            }

            Section {
                Button("打开设置", action: openSettings)
            } header: {
                stepTitle("2. 添加键盘")
            }

            Section {
                Toggle("左手", isOn: layoutSelection(.left)).toggleStyle(.switch).tint(.green)
                Toggle("右手", isOn: layoutSelection(.right)).toggleStyle(.switch).tint(.green)
                if layoutError { Text("布局未保存，请重试。") }
            } header: {
                stepTitle("键盘布局")
            }

            Section {
                Picker("服务", selection: $provider) {
                    Text("OpenAI").tag("OpenAI")
                    Text("豆包").tag("Doubao")
                }.pickerStyle(.menu)
                .onChange(of: provider, initial: true) {
                    key = ""
                    keyError = !APIKeyStore.save(provider, "Calci.Provider")
                    saved = APIKeyStore.read("Calci." + provider) != nil
                }
                SecureField(saved ? "输入新密钥" : "输入 API 密钥", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !key.isEmpty {
                    Button("保存密钥") {
                        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyError = value.isEmpty || !APIKeyStore.save(value, "Calci." + provider)
                        if !keyError { saved = true; key = "" }
                    }
                } else if saved {
                    Button("移除已保存的密钥", role: .destructive) {
                        keyError = !APIKeyStore.remove("Calci." + provider)
                        if !keyError { saved = false }
                    }
                }
                if keyError { Text("密钥未更新，请重试。") }
            } header: { stepTitle("转写") }

            Section {
                TextField("听写结果会出现在这里", text: $text, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                stepTitle("3. 试一句")
            } footer: {
                Text("切到 Calci，按住圆键说话，松手结束。")
            }
        }
        .navigationTitle("Calci")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase, initial: true) {
            guard scenePhase == .active else { return }
            microphone = AVAudioApplication.shared.recordPermission
        }
    }

    private func layoutSelection(_ hand: KeyboardHand) -> Binding<Bool> {
        Binding(
            get: { keyboardHand == hand },
            set: { enabled in
                let selected: KeyboardHand = enabled ? hand : (hand == .left ? .right : .left)
                guard selected != keyboardHand else { return }
                layoutError = !selected.save()
                if !layoutError { keyboardHand = selected }
            }
        )
    }

    private func stepTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var microphoneStatus: String {
        switch microphone {
        case .granted: "已允许"
        case .denied: "未允许"
        default: "未请求"
        }
    }

    private func requestMicrophone() {
        Task { @MainActor in
            _ = await AVAudioApplication.requestRecordPermission()
            microphone = AVAudioApplication.shared.recordPermission
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

}

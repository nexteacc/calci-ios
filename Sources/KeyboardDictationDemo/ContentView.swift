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
                Picker("操作手", selection: Binding(get: { keyboardHand }, set: { hand in
                    layoutError = !hand.save()
                    if !layoutError { keyboardHand = hand }
                })) {
                    Text("左手").tag(KeyboardHand.left)
                    Text("右手").tag(KeyboardHand.right)
                }
                .pickerStyle(.segmented)
                if layoutError { Text("布局未保存，请重试。") }
            } header: {
                stepTitle("键盘布局")
            }

            Section {
                Picker("服务", selection: .constant("OpenAI")) {
                    Text("OpenAI").tag("OpenAI")
                }.pickerStyle(.menu)
                SecureField(saved ? "输入新密钥" : "输入 API 密钥", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !key.isEmpty {
                    Button("保存密钥") {
                        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyError = value.isEmpty || !APIKeyStore.save(value)
                        if !keyError { saved = true; key = "" }
                    }
                } else if saved {
                    Button("移除已保存的密钥", role: .destructive) {
                        keyError = !APIKeyStore.remove()
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

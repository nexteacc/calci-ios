# Calci

Calci 是 iPhone 上的语音键盘。在支持第三方键盘的输入框中切换到 Calci，按住圆形按钮说话，转写文字会逐步出现在光标处。松手后，键盘用最终识别结果校正文字。

## 使用

1. 用 Xcode 打开 `KeyboardDictationDemo.xcodeproj`，为应用和键盘扩展配置开发签名，安装到 iPhone。
2. 打开 Calci，允许使用麦克风，填入自己的 OpenAI API 密钥并保存。应用和键盘扩展通过 iOS 钥匙串共享密钥。
3. 在系统键盘设置中添加 Calci 并允许完全访问，回到输入框切换键盘即可使用。

录音期间，键盘将 24 kHz 单声道音频直接发送到 OpenAI 实时转写服务。当前模型为 `gpt-live-transcribe`，配置了中英文混合口述提示。

## 项目来源

Calci 基于 Stephan Cilliers 的 [ios-keyboard-dictation](https://github.com/stephancill/ios-keyboard-dictation) 开始开发，沿用了原项目通过 WebKit 在键盘内采集麦克风音频的方法。感谢 Stephan 分享实现和代码。

Calci 现由本仓库独立维护。在原项目的基础上，我们接入了 OpenAI 实时转写，加入了个人密钥配置、连接诊断，并为长按录音、频谱反馈和发送操作设计了键盘交互。

项目采用 [MIT 许可证](LICENSE)，保留原作者的版权声明。

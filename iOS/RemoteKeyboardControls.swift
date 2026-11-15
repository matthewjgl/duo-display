import SwiftUI
import UIKit

struct RemoteKeyboardControls: View {
    @ObservedObject var receiver: StreamReceiver
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment:.leading,spacing:6) {
                // No persistent keyboard pill. Dismiss overlays the video only
                // during editing, reserving no accessory strip above the keys.
                if let error = receiver.keyboardError {
                    Text(error).font(.caption).padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
                }
                Spacer()
            }.frame(maxWidth:280,alignment:.leading)
                .padding(.leading,geometry.safeAreaInsets.leading+12)
                .padding(.top,geometry.safeAreaInsets.top+8)
            if receiver.connected && receiver.keyboardPresentation.visible {
                VStack {
                    Spacer(minLength:0)
                    HStack {
                        Spacer(minLength:0)
                        Button { receiver.hidePhoneKeyboard() } label: {
                            Image(systemName:"keyboard.chevron.compact.down")
                                .font(.body.weight(.semibold)).frame(width:44,height:44)
                                .background(.regularMaterial,in:Circle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Hide keyboard")
                            .accessibilityHint("Keep the Mac field focused and restore the full desktop")
                    }
                }.padding(.trailing,geometry.safeAreaInsets.trailing+12).padding(.bottom,8)
            }
            RemoteKeyboardEditor(receiver:receiver).frame(width:1,height:1).opacity(0.01).accessibilityHidden(true)
        }
    }
}

private struct RemoteKeyboardEditor: UIViewRepresentable {
    @ObservedObject var receiver: StreamReceiver
    func makeCoordinator() -> Coordinator { Coordinator(receiver:receiver) }
    func makeUIView(context:Context) -> CommitTextView {
        let view = CommitTextView()
        view.text = KeyboardText.sentinel; view.selectedRange = NSRange(location:1,length:0)
        view.delegate = context.coordinator; context.coordinator.view = view
        view.onUnmark = { [weak coordinator = context.coordinator] view in coordinator?.textViewDidChange(view) }
        view.autocorrectionType = .no; view.spellCheckingType = .no
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.textContentType = nil; view.isScrollEnabled = false
        view.inputAssistantItem.leadingBarButtonGroups = []; view.inputAssistantItem.trailingBarButtonGroups = []
        // An inputAccessoryView reserves its own keyboard-height strip even
        // when visually transparent. The dismiss control lives over video.
        view.inputAccessoryView = nil
        receiver.resignPhoneKeyboard = { [weak view] in view?.unmarkText(); view?.resignFirstResponder() }
        return view
    }
    func updateUIView(_ view:CommitTextView,context:Context) {
        let visible = receiver.connected && receiver.keyboardPresentation.visible
        if visible && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak receiver] in
                guard receiver?.keyboardPresentation.visible == true else { return }
                view?.becomeFirstResponder()
            }
        } else if !visible && view.isFirstResponder {
            // Focus loss/disconnect must never commit buffered text into a new app.
            context.coordinator.reset(view); view.resignFirstResponder()
        }
    }
    static func dismantleUIView(_ view:CommitTextView,coordinator:Coordinator) {
        view.delegate = nil; view.text = ""; view.resignFirstResponder()
    }
    final class CommitTextView: UITextView {
        var onUnmark: ((UITextView) -> Void)?
        override func unmarkText() { super.unmarkText(); onUnmark?(self) }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var receiver:StreamReceiver?
        weak var view:UITextView?
        private var resetting = false
        init(receiver:StreamReceiver) { self.receiver = receiver }
        func reset(_ view:UITextView) {
            resetting = true; view.text = KeyboardText.sentinel
            view.selectedRange = NSRange(location:1,length:0); resetting = false
        }
        func textView(_ textView:UITextView, shouldChangeTextIn range:NSRange,replacementText text:String) -> Bool {
            guard !resetting else { return false }
            if textView.markedTextRange == nil && textView.text == KeyboardText.sentinel {
                if text.isEmpty && range.length > 0 { receiver?.sendKeyboard(.backspace); return false }
                if text == "\n" { receiver?.sendKeyboard(.enter); return false }
            }
            return true
        }
        func textViewDidChange(_ textView:UITextView) {
            guard !resetting, let committed = KeyboardText.committed(textView.text,marked:textView.markedTextRange != nil) else { return }
            // Bounded frames preserve Unicode boundaries and TCP ordering. No
            // transcript, clipboard access, retries or persistent text buffer.
            for chunk in KeyboardText.chunks(committed,maxUnits:1024) {
                receiver?.sendKeyboard(.text,text:String(decoding:chunk,as:UTF16.self))
            }
            reset(textView)
        }
    }
}

//
//  LoginView.swift
//  ClawWatch iOS
//
//  Reuses the shared LoginViewModel (QR + phone auth).
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {

    @State private var vm = LoginViewModel()
    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("ClawWatch")
                        .font(.largeTitle.bold())

                    if vm.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        qrSection
                        Divider()
                        phoneSection
                    }
                }
                .padding()
            }
            .navigationTitle("Sign In")
            .sheet(isPresented: vm.showCode) { codeSheet }
            .sheet(isPresented: vm.showPassword) { passwordSheet }
        }
    }

    // MARK: - QR

    private var qrSection: some View {
        VStack(spacing: 12) {
            Text("Scan with Telegram")
                .font(.headline)
            Text("Settings → Devices → Link Desktop Device")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let link = vm.qrCodeLink, let image = qrImage(from: link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView().frame(width: 220, height: 220)
            }
        }
    }

    // MARK: - Phone

    private var phoneSection: some View {
        VStack(spacing: 12) {
            Text("Or sign in with your phone")
                .font(.headline)
            TextField("+1 555 555 5555", text: $phoneNumber)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad)
            Button("Send Code") {
                vm.setPhoneNumber(phoneNumber.filter { !$0.isWhitespace })
            }
            .buttonStyle(.borderedProminent)
            .disabled(phoneNumber.isEmpty)

            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text("Tip: include your country code, e.g. +1 704…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var codeSheet: some View {
        authSheet(title: "Enter Code", field: $code, keyboard: .numberPad) {
            vm.validateAuthCode(code)
        }
    }

    private var passwordSheet: some View {
        authSheet(title: "Two-Factor Password", field: $password, secure: true) {
            vm.validatePassword(password)
        }
    }

    private func authSheet(
        title: String,
        field: Binding<String>,
        keyboard: UIKeyboardType = .default,
        secure: Bool = false,
        submit: @escaping () -> Void
    ) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if secure {
                        SecureField(title, text: field)
                    } else {
                        TextField(title, text: field)
                            .keyboardType(keyboard)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button("Continue", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(field.wrappedValue.isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle(title)
        }
    }

    // MARK: - QR rendering (CoreImage, no extra dependency)

    private func qrImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

import SwiftUI
import DiskMapCore

/// Aviso cuando falta el Acceso total al disco: la app funciona, pero no ve todo.
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model
    var onDismiss: () -> Void

    var body: some View {
        GlassCard(padding: 16, radius: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xFFB340), Color(hex: 0xFF9F0A)],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Airy no puede ver todo el disco")
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                PrimaryButton("Dar acceso", systemImage: "gearshape") {
                    model.openFullDiskAccessSettings()
                }
                .fixedSize()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Ocultar hasta la próxima vez")
            }
        }
    }

    private var detail: String {
        let base = "Activa Airy en Ajustes del Sistema › Privacidad y seguridad › Acceso total al disco para incluir Mail, Safari y los datos protegidos de las apps."
        let count = model.inaccessibleCount
        guard count > 0 else { return base }
        let folders = count == 1 ? "1 carpeta" : "\(Theme.count(count)) carpetas"
        return "\(base) Ahora se omiten \(folders)."
    }
}

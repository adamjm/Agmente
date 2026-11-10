import SwiftUI

/// The grey, sentence-case label above a settings card.
struct SettingsSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded group of rows. Each row draws its own hairline when `showsDivider` is set.
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(ForkColor.surfaceRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One settings row: a leading outline icon in a 28 pt frame, a title, an optional subtitle and grey value,
/// an optional trailing view, and a chevron when the row opens a screen. The row is at least 44 pt tall.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let value: String?
    let iconColor: Color
    let titleColor: Color
    let showsChevron: Bool
    let showsDivider: Bool
    let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        iconColor: Color = .secondary,
        titleColor: Color = .primary,
        showsChevron: Bool = false,
        showsDivider: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.iconColor = iconColor
        self.titleColor = titleColor
        self.showsChevron = showsChevron
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(titleColor)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                trailing
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            if showsDivider {
                Divider()
                    .padding(.leading, 56)
            }
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        iconColor: Color = .secondary,
        titleColor: Color = .primary,
        showsChevron: Bool = false,
        showsDivider: Bool = false
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            value: value,
            iconColor: iconColor,
            titleColor: titleColor,
            showsChevron: showsChevron,
            showsDivider: showsDivider
        ) { EmptyView() }
    }
}

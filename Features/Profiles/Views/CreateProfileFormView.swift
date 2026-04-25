import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// System-styled create-profile form (states 2 and 3). Single required
/// field (Name); Currency + Financial year start are behind an Advanced
/// disclosure with locale defaults.
///
/// Background iCloud-checking spinner is owned by the host — pass it via
/// `backgroundCheckingICloud`. The optional banner is rendered above
/// the form when `banner` is non-nil (state 3).
///
/// On iOS, the "Create Profile" button fires a `.success` notification
/// haptic when the async create completes (design spec §4.3).
struct CreateProfileFormView: View {
  @Binding var name: String
  @Binding var currency: Instrument
  @Binding var financialYearStartMonth: Int
  let banner: ICloudArrivalBanner.Kind?
  let onBannerPrimary: () -> Void
  let onBannerDismiss: () -> Void
  let backgroundCheckingICloud: Bool
  let cancelAction: () -> Void
  let createAction: () async -> Void

  @State private var isSubmitting = false
  @FocusState private var focus: Focus?

  private enum Focus: Hashable {
    case name
  }

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  private static let commonCurrencyCodes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ]

  private static let sortedCurrencyCodes: [String] = commonCurrencyCodes.sorted {
    Instrument.localizedName(for: $0).localizedCaseInsensitiveCompare(
      Instrument.localizedName(for: $1)
    ) == .orderedAscending
  }

  var body: some View {
    VStack(spacing: 0) {
      bannerContent
      form
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(String(localized: "Cancel"), action: cancelAction)
      }
      ToolbarItem(placement: .confirmationAction) {
        confirmationButton
      }
    }
    // Initial focus is declared via `.defaultFocus($focus, .name)` on
    // the inner `Form` (see `form` below). Re-setting `focus` here in
    // `onAppear` would race the declarative resolver.
  }

  @ViewBuilder private var bannerContent: some View {
    if let banner {
      ICloudArrivalBanner(
        kind: banner,
        primaryAction: onBannerPrimary,
        dismissAction: onBannerDismiss
      )
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .accessibilityIdentifier(
        banner.isSingle
          ? UITestIdentifiers.Welcome.bannerOpenAction
          : UITestIdentifiers.Welcome.bannerViewAction
      )
    }
  }

  private var form: some View {
    Form {
      Section {
        // `.onSubmit` is attached to the TextField directly (not the
        // parent `Form`) so Return inside the DisclosureGroup's
        // Currency / FY-month Picker doesn't also fire `submit`.
        TextField(String(localized: "Name"), text: $name)
          .focused($focus, equals: .name)
          .submitLabel(.done)
          .onSubmit(submit)
          .accessibilityIdentifier(UITestIdentifiers.Welcome.nameField)
        advancedDisclosure
      } header: {
        header
      } footer: {
        footer
      }
    }
    .formStyle(.grouped)
    // `defaultFocus` is the canonical SwiftUI API for initial focus.
    // `.onAppear { focus = .name }` alone was insufficient on macOS —
    // the DisclosureGroup was claiming first-responder before the
    // TextField was ready to accept focus.
    .defaultFocus($focus, .name)
  }

  private var advancedDisclosure: some View {
    DisclosureGroup(
      String(localized: "Advanced", comment: "Form advanced disclosure")
    ) {
      Picker(
        String(localized: "Currency", comment: "Form currency picker"),
        selection: Binding(
          get: { currency.id },
          set: { currency = Instrument.fiat(code: $0) }
        )
      ) {
        ForEach(Self.sortedCurrencyCodes, id: \.self) { code in
          Text("\(code) — \(Instrument.localizedName(for: code))").tag(code)
        }
      }
      .pickerStyle(.menu)
      Picker(
        String(localized: "Financial year starts", comment: "Form FY month"),
        selection: $financialYearStartMonth
      ) {
        ForEach(1...12, id: \.self) { month in
          if month <= Self.monthNames.count {
            Text(Self.monthNames[month - 1]).tag(month)
          }
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Create a profile", comment: "Form title")
        .font(.title2.bold())
        .foregroundStyle(.primary)
        .textCase(nil)
      Text(
        "Just give it a name. You can tweak the rest later.",
        comment: "Form subtitle"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .textCase(nil)
    }
    .padding(.bottom, 8)
  }

  @ViewBuilder private var footer: some View {
    if backgroundCheckingICloud {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Still checking iCloud…", comment: "Form background status")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var confirmationButton: some View {
    if isSubmitting {
      ProgressView().controlSize(.small)
    } else {
      Button(action: submit) {
        Text("Create Profile", comment: "Form primary CTA")
      }
      .buttonStyle(.borderedProminent)
      .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      .accessibilityIdentifier(UITestIdentifiers.Welcome.createProfileButton)
    }
  }

  private func submit() {
    // Guard here so keyboard submit (Return in the Name field) respects
    // the same preconditions as the toolbar button — which disables
    // itself via the modifier rather than hand-rolling a `guard`.
    guard !isSubmitting,
      !name.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    isSubmitting = true
    Task {
      await createAction()
      isSubmitting = false
      #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
  }
}

extension ICloudArrivalBanner.Kind {
  // Internal (default) — the sibling view is in the same module; keeping
  // file scope isn't strictly necessary and `strict_fileprivate` flags it.
  var isSingle: Bool {
    if case .single = self { return true }
    return false
  }
}

#Preview("Create — default") {
  @Previewable @State var name = ""
  @Previewable @State var currency: Instrument = .AUD
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currency: $currency,
      financialYearStartMonth: $month,
      banner: nil,
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: true,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 480, height: 560)
}

#Preview("Create — with banner") {
  @Previewable @State var name = "Hous"
  @Previewable @State var currency: Instrument = .AUD
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currency: $currency,
      financialYearStartMonth: $month,
      banner: .single(label: "Household"),
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: true,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 480, height: 600)
}

#Preview("Create — dark") {
  @Previewable @State var name = "Household"
  @Previewable @State var currency: Instrument = .AUD
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currency: $currency,
      financialYearStartMonth: $month,
      banner: nil,
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: false,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 480, height: 560)
  .preferredColorScheme(.dark)
}

#Preview("Create — AX5") {
  @Previewable @State var name = "Household"
  @Previewable @State var currency: Instrument = .AUD
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currency: $currency,
      financialYearStartMonth: $month,
      banner: nil,
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: false,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 600, height: 800)
  .dynamicTypeSize(.accessibility5)
}

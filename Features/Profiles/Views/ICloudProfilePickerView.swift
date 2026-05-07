import SwiftUI

/// State 5 — picker surfaced when iCloud returns two or more profiles.
/// Plain `List` with native rows plus a "+ Create a new profile" footer
/// row.
///
/// Account-count meta text uses `.monospacedDigit()` per
/// `guides/UI_GUIDE.md` §4 — prevents row-width jitter as sync delivers
/// data.
struct ICloudProfilePickerView: View {
  let profiles: [Profile]
  let accountCounts: [UUID: Int]
  let incompatibleProfileIDs: Set<UUID>
  let selectAction: (Profile) -> Void
  let createNewAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)

      List {
        profilesSection
        createSection
      }
      .listStyle(.inset)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Welcome back.", comment: "Picker title")
        .font(.title2.bold())
      Text(
        "You have profiles in iCloud. Pick one to open.",
        comment: "Picker subtitle"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var profilesSection: some View {
    Section {
      ForEach(profiles) { profile in
        Button {
          selectAction(profile)
        } label: {
          row(for: profile)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(UITestIdentifiers.Welcome.pickerRow(profile.id))
      }
    } header: {
      Text("Your profiles", comment: "Picker section header")
    }
  }

  private var createSection: some View {
    Section {
      Button(action: createNewAction) {
        Label(
          String(localized: "Create a new profile", comment: "Picker footer CTA"),
          systemImage: "plus"
        )
        .foregroundStyle(.tint)
      }
      .accessibilityIdentifier(UITestIdentifiers.Welcome.pickerCreateNewRow)
    }
  }

  private func row(for profile: Profile) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.label)
          .font(.body.weight(.medium))
        metaRow(for: profile)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if profile.dataFormatVersion > DataFormatVersion.current
        || incompatibleProfileIDs.contains(profile.id)
      {
        Text("Update required", comment: "Profile picker badge for incompatible profiles")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.15), in: Capsule())
      }
      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
        .font(.caption)
    }
    .contentShape(.rect)
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func metaRow(for profile: Profile) -> some View {
    if let count = accountCounts[profile.id] {
      HStack(spacing: 4) {
        Text(profile.currencyCode)
        Text("·")
        Text(
          "\(count) \(count == 1 ? String(localized: "account") : String(localized: "accounts"))"
        )
        .monospacedDigit()
      }
    } else {
      Text(profile.currencyCode)
    }
  }
}

#Preview("Two profiles") {
  ICloudProfilePickerView(
    profiles: [
      Profile(label: "Household", currencyCode: "AUD"),
      Profile(label: "Side business", currencyCode: "AUD"),
    ],
    accountCounts: [:],
    incompatibleProfileIDs: [],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 480, height: 520)
}

#Preview("With counts — dark") {
  let household = Profile(label: "Household", currencyCode: "AUD")
  let business = Profile(label: "Side business", currencyCode: "AUD")
  ICloudProfilePickerView(
    profiles: [household, business],
    accountCounts: [household.id: 12, business.id: 3],
    incompatibleProfileIDs: [],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 480, height: 520)
  .preferredColorScheme(.dark)
}

#Preview("AX5") {
  let household = Profile(label: "Household", currencyCode: "AUD")
  ICloudProfilePickerView(
    profiles: [household],
    accountCounts: [household.id: 12],
    incompatibleProfileIDs: [],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 600, height: 800)
  .dynamicTypeSize(.accessibility5)
}

#Preview("Incompatible badge") {
  let household = Profile(label: "Household", currencyCode: "AUD")
  let business = Profile(label: "Side business", currencyCode: "AUD")
  ICloudProfilePickerView(
    profiles: [household, business],
    accountCounts: [household.id: 12, business.id: 3],
    incompatibleProfileIDs: [business.id],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 480, height: 520)
}

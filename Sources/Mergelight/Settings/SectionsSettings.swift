import MergelightKit
import SwiftUI

/// Master-detail editor for sections: reorderable list on the left, the selected one on the right.
struct SectionsSettings: View {
  @Bindable var model: AppModel
  @State private var selection: UUID?
  @State private var confirmReset = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(model.settings.sections) { section in
            HStack(spacing: 6) {
              Circle().fill(section.color.color).frame(width: 8, height: 8)
              Text(section.name).lineLimit(1)
              Spacer()
              if section.tab == .review {
                Image(systemName: "eyes").foregroundStyle(.secondary).help("To review tab")
              }
              if !section.isEnabled {
                Image(systemName: "eye.slash").foregroundStyle(.tertiary).help("Disabled")
              }
            }
            .opacity(section.isEnabled ? 1 : 0.55)
            .tag(section.id)
          }
          .onMove { model.settings.sections.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))

        HStack(spacing: 0) {
          Button {
            let section = SectionConfig(name: "New section", color: .blue, query: "is:pr is:open author:@me")
            model.settings.sections.append(section)
            selection = section.id
          } label: {
            Image(systemName: "plus").frame(width: 24, height: 20)
          }
          Button {
            guard let selection else { return }
            model.settings.sections.removeAll { $0.id == selection }
            self.selection = model.settings.sections.first?.id
          } label: {
            Image(systemName: "minus").frame(width: 24, height: 20)
          }
          .disabled(selection == nil)
          Spacer()
          Button("Reset…") { confirmReset = true }
            .controlSize(.small)
        }
        .buttonStyle(.borderless)
        .padding(6)
      }
      .frame(width: 210)

      Divider()

      if let selection, let section = model.settings.sections.first(where: { $0.id == selection }) {
        SectionEditor(section: binding(for: selection, fallback: section), model: model)
      } else {
        Text("Select a section")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(16)
    .onAppear { selection = selection ?? model.settings.sections.first?.id }
    .confirmationDialog("Replace all sections with the defaults?", isPresented: $confirmReset) {
      Button("Reset Sections", role: .destructive) {
        Task {
          await model.resetSectionsToDefaults()
          selection = model.settings.sections.first?.id
        }
      }
    } message: {
      Text("Creates one section per organization, Personal, Elsewhere and Review requests.")
    }
  }

  /// Looks the section up by ID on every access. An index binding would crash when the section
  /// is deleted while its editor is still on screen.
  private func binding(for id: UUID, fallback: SectionConfig) -> Binding<SectionConfig> {
    Binding(
      get: { model.settings.sections.first { $0.id == id } ?? fallback },
      set: { newValue in
        guard let index = model.settings.sections.firstIndex(where: { $0.id == id }) else { return }
        model.settings.sections[index] = newValue
      })
  }
}

private struct SectionEditor: View {
  @Binding var section: SectionConfig
  let model: AppModel
  /// Raw text, so separators survive while typing; parsed into `section.repos` on every edit.
  @State private var repoText = ""

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $section.name)
        LabeledContent("Color") {
          HStack(spacing: 6) {
            ForEach(SectionColor.allCases) { color in
              Circle()
                .fill(color.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.primary, lineWidth: section.color == color ? 2 : 0).padding(-3))
                .onTapGesture { section.color = color }
                .help(color.rawValue.capitalized)
            }
          }
        }
        Picker("Tab", selection: $section.tab) {
          ForEach(SectionConfig.Tab.allCases) { Text($0.title).tag($0) }
        }
      }

      Section {
        TextField("Query", text: $section.query, axis: .vertical)
          .font(.system(.body, design: .monospaced))
          .lineLimit(2...4)
        HStack {
          Text("GitHub search syntax. is:pr and sort:updated-desc are added if missing.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Try on GitHub") { model.open(section.webSearchURL) }
            .controlSize(.small)
        }
      } header: {
        Text("Search")
      }

      Section {
        Picker("Repositories", selection: $section.repoFilterMode) {
          ForEach(SectionConfig.RepoFilterMode.allCases) { Text($0.title).tag($0) }
        }
        if section.repoFilterMode != .all {
          TextField("owner/repo, owner/other", text: $repoText, axis: .vertical)
            .lineLimit(1...3)
            .onChange(of: repoText) { _, text in
              section.repos = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            }
          let invalid = section.repos.count - section.normalizedRepos.count
          if invalid > 0 {
            Text("\(invalid) entr\(invalid == 1 ? "y isn't" : "ies aren't") in owner/repo form and will be ignored.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }

      Section {
        Toggle("Enabled", isOn: $section.isEnabled)
        Toggle("Hide when empty", isOn: $section.hideWhenEmpty)
        Toggle("Count in menu bar", isOn: $section.countsInMenuBar)
      }
    }
    .formStyle(.grouped)
    .onAppear { repoText = section.repos.joined(separator: ", ") }
    .onChange(of: section.id) { repoText = section.repos.joined(separator: ", ") }
  }
}

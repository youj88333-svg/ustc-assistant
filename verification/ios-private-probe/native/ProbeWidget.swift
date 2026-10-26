import SwiftUI
import WidgetKit

private struct I0ProbeEntry: TimelineEntry {
  let date: Date
  let snapshot: I0SharedSnapshot.Result

  static var unavailable: I0ProbeEntry {
    I0ProbeEntry(
      date: Date(),
      snapshot: I0SharedSnapshot.Result(
        groupAvailable: false,
        groupDigest: nil,
        marker: nil,
        markerCreatedAt: nil,
        failure: "shared_group_unavailable"
      )
    )
  }
}

private struct I0ProbeProvider: TimelineProvider {
  func placeholder(in context: Context) -> I0ProbeEntry {
    .unavailable
  }

  func getSnapshot(in context: Context, completion: @escaping (I0ProbeEntry) -> Void) {
    completion(I0ProbeEntry(date: Date(), snapshot: I0SharedSnapshot.inspect()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<I0ProbeEntry>) -> Void) {
    let entry = I0ProbeEntry(date: Date(), snapshot: I0SharedSnapshot.inspect())
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
  }
}

private struct I0ProbeWidgetView: View {
  let entry: I0ProbeEntry

  private var hasSharedMarker: Bool {
    entry.snapshot.groupAvailable && entry.snapshot.failure == nil && entry.snapshot.marker != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("iOS I0 共享探针")
        .font(.caption)
        .foregroundStyle(.secondary)
      if hasSharedMarker, let marker = entry.snapshot.marker,
        let createdAt = entry.snapshot.markerCreatedAt
      {
        Text(marker)
          .font(.headline.monospaced())
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Text(createdAt)
          .font(.caption2.monospacedDigit())
          .lineLimit(2)
          .minimumScaleFactor(0.75)
      } else {
        Text("共享不可用")
          .font(.headline)
        Text("请打开探针")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding()
    .containerBackground(.background, for: .widget)
    .widgetURL(URL(string: "ustc-ios-i0://probe"))
  }
}

@main
struct I0ProbeWidget: Widget {
  let kind = "I0ProbeWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: I0ProbeProvider()) { entry in
      I0ProbeWidgetView(entry: entry)
    }
    .configurationDisplayName("iOS I0 探针")
    .description("只读显示主应用写入的合成共享标记。")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

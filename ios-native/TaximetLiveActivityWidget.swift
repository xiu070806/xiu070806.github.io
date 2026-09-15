import ActivityKit
import WidgetKit
import SwiftUI

private func liveDistance(_ meters: Double) -> String {
    String(format: "%.2f km", max(0, meters) / 1000.0)
}

private func liveFare(_ amount: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = "."
    f.locale = Locale(identifier: "vi_VN")
    return (f.string(from: NSNumber(value: max(0, amount))) ?? "0") + "đ"
}

private struct LiveActivityMainView: View {
    let context: ActivityViewContext<TaximetLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TAXIMET PRO").font(.headline).fontWeight(.black)
                Spacer()
                Text(context.state.status == "PAUSED" ? "TẠM DỪNG" : "ĐANG CHẠY")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(context.state.status == "PAUSED" ? .orange : .green)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(liveFare(context.state.fare)).font(.system(size: 28, weight: .black))
                Spacer()
                Text(liveDistance(context.state.distanceM)).font(.headline)
            }
            HStack {
                Text(context.state.tripCode).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(context.state.updatedAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
        .activityBackgroundTint(Color(red: 0.04, green: 0.10, blue: 0.15))
        .activitySystemActionForegroundColor(.white)
    }
}

struct TaximetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaximetLiveActivityAttributes.self) { context in
            LiveActivityMainView(context: context)
                .widgetURL(URL(string: "taximetpro://trip/\(context.attributes.tripId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TAXIMET PRO").font(.caption).fontWeight(.black)
                        Text(context.state.tripCode).font(.caption2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(liveFare(context.state.fare)).font(.headline).fontWeight(.black)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 12) {
                        Label(liveDistance(context.state.distanceM), systemImage: "location.fill")
                        Label(context.state.status == "PAUSED" ? "Tạm dừng" : "Đang chạy", systemImage: context.state.status == "PAUSED" ? "pause.fill" : "car.fill")
                    }.font(.caption).fontWeight(.bold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Chạm để mở TAXIMET PRO").font(.caption2).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text("🚕").font(.caption)
            } compactTrailing: {
                Text(liveFare(context.state.fare)).font(.caption).fontWeight(.bold)
            } minimal: {
                Text("🚕").font(.caption)
            }
            .widgetURL(URL(string: "taximetpro://trip/\(context.attributes.tripId)"))
            .keylineTint(.green)
        }
    }
}

@main
struct TaximetLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaximetLiveActivityWidget()
    }
}

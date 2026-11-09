import Foundation

public enum WebChartType: String {
    case bar
    case line
    case pie
    case doughnut
    case radar
    case polarArea
    case bubble
    case scatter
}

public enum ChartLegendPosition: String {
    case top
    case bottom
    case left
    case right
}

public enum ChartColorValue: Encodable {
    case single(String)
    case multiple([String])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let color):
            try container.encode(color)
        case .multiple(let colors):
            try container.encode(colors)
        }
    }
}

public struct ChartDataSet: Encodable {
    public var label: String?
    public var data: [Double]
    public var backgroundColor: ChartColorValue?
    public var borderColor: ChartColorValue?
    public var borderWidth: Int?
    public var fill: Bool?
    public var tension: Double?

    public init(label: String? = nil, values: [Double]) {
        self.label = label
        self.data = values
    }

    public init(label: String? = nil, values: [Int]) {
        self.label = label
        self.data = values.map { Double($0) }
    }

    @discardableResult
    public func background(_ color: WebColor) -> Self {
        var copy = self
        copy.backgroundColor = .single(color.rgba)
        return copy
    }

    @discardableResult
    public func background(_ color: String) -> Self {
        var copy = self
        copy.backgroundColor = .single(color)
        return copy
    }

    @discardableResult
    public func background(_ colors: [WebColor]) -> Self {
        var copy = self
        copy.backgroundColor = .multiple(colors.map { $0.rgba })
        return copy
    }

    @discardableResult
    public func background(_ colors: [String]) -> Self {
        var copy = self
        copy.backgroundColor = .multiple(colors)
        return copy
    }

    @discardableResult
    public func border(_ color: WebColor) -> Self {
        var copy = self
        copy.borderColor = .single(color.rgba)
        return copy
    }

    @discardableResult
    public func border(_ color: String) -> Self {
        var copy = self
        copy.borderColor = .single(color)
        return copy
    }

    @discardableResult
    public func border(_ colors: [WebColor]) -> Self {
        var copy = self
        copy.borderColor = .multiple(colors.map { $0.rgba })
        return copy
    }

    @discardableResult
    public func border(_ colors: [String]) -> Self {
        var copy = self
        copy.borderColor = .multiple(colors)
        return copy
    }

    @discardableResult
    public func borderWidth(_ value: Int) -> Self {
        var copy = self
        copy.borderWidth = value
        return copy
    }

    @discardableResult
    public func fill(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.fill = enabled
        return copy
    }

    @discardableResult
    public func tension(_ value: Double) -> Self {
        var copy = self
        copy.tension = value
        return copy
    }
}

public struct ChartData {
    public var labels: [String]
    public var dataSets: [ChartDataSet]

    public init(labels: [String], dataSets: [ChartDataSet]) {
        self.labels = labels
        self.dataSets = dataSets
    }
}

public typealias DataSet = ChartDataSet

public struct ChartOptions {
    public var responsive: Bool
    public var maintainAspectRatio: Bool
    public var beginAtZero: Bool
    public var stackedX: Bool
    public var stackedY: Bool
    public var legendPosition: ChartLegendPosition?
    public var title: String?

    public init(
        responsive: Bool = true,
        maintainAspectRatio: Bool = false,
        beginAtZero: Bool = true,
        stackedX: Bool = false,
        stackedY: Bool = false,
        legendPosition: ChartLegendPosition? = .top,
        title: String? = nil
    ) {
        self.responsive = responsive
        self.maintainAspectRatio = maintainAspectRatio
        self.beginAtZero = beginAtZero
        self.stackedX = stackedX
        self.stackedY = stackedY
        self.legendPosition = legendPosition
        self.title = title
    }
}

public class WebChartElement: WebElement {}

/// Encodes a value as a JSON literal for the chart's `<script>`. The output is script-safe (see
/// `ScriptValue.json`), so labels/titles can't close the script element or break the literal. Keys are
/// sorted: JSONEncoder's own key order changes from one encoding to the next, so the same chart rendered a
/// different page each time.
private func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let json = String(data: data, encoding: .utf8) else {
        return "null"
    }
    return ScriptValue.json(json)
}

private extension ChartOptions {
    var jsObject: String {
        let legendString: String
        if let position = legendPosition {
            legendString = "legend: { display: true, position: \(encodeJSON(position.rawValue)) }"
        } else {
            legendString = "legend: { display: false }"
        }

        let titleString: String
        if let title, !title.isEmpty {
            titleString = "title: { display: true, text: \(encodeJSON(title)) }"
        } else {
            titleString = "title: { display: false }"
        }

        return """
        {
          responsive: \(responsive ? "true" : "false"),
          maintainAspectRatio: \(maintainAspectRatio ? "true" : "false"),
          scales: {
            x: { stacked: \(stackedX ? "true" : "false") },
            y: { stacked: \(stackedY ? "true" : "false"), beginAtZero: \(beginAtZero ? "true" : "false") }
          },
          plugins: {
            \(legendString),
            \(titleString)
          }
        }
        """
    }
}

private extension CoreWebEndpoint {
    func ensureChartJSPackageImported() {
        let chartCDN = "https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"
        let alreadyImported = headAttributes.contains {
            switch $0 {
            case .script(let src, _, _, _, _, _, _):
                return src.lowercased().contains("chart.js")
            default:
                return false
            }
        }

        if !alreadyImported {
            head(.script(src: chartCDN))
        }
    }
}

public extension CoreWebEndpoint {
    @discardableResult
    func Chart(
        id: String? = nil,
        type: WebChartType = .bar,
        data: ChartData,
        options: ChartOptions = ChartOptions()
    ) -> WebChartElement {
        ensureChartJSPackageImported()

        let chart = WebChartElement()
        populateCreatedObject(chart)
        chart.elementName = "canvas"
        chart.class("wsui-chart")

        let canvasId = id ?? "chart_\(chart.builderId)"
        chart.id(canvasId)

        let labelsJSON = encodeJSON(data.labels)
        let dataSetsJSON = encodeJSON(data.dataSets)
        let chartTypeJSON = encodeJSON(type.rawValue)
        let canvasIdJSON = encodeJSON(canvasId)

        chart.addAttribute(.domLoadedScript("""
        (function() {
            var canvas = document.getElementById(\(canvasIdJSON));
            if (!canvas || typeof Chart === 'undefined') { return; }
        
            window._wsuiCharts = window._wsuiCharts || {};
            if (window._wsuiCharts[\(canvasIdJSON)]) {
                try { window._wsuiCharts[\(canvasIdJSON)].destroy(); } catch (_) { }
            }
        
            window._wsuiCharts[\(canvasIdJSON)] = new Chart(canvas, {
                type: \(chartTypeJSON),
                data: {
                    labels: \(labelsJSON),
                    datasets: \(dataSetsJSON)
                },
                options: \(options.jsObject)
            });
        })();
        """))

        return chart
    }

    @discardableResult
    func Chart(
        id: String? = nil,
        type: WebChartType = .bar,
        labels: [String],
        dataSets: [ChartDataSet],
        options: ChartOptions = ChartOptions()
    ) -> WebChartElement {
        Chart(
            id: id,
            type: type,
            data: ChartData(labels: labels, dataSets: dataSets),
            options: options
        )
    }

    @discardableResult
    func Chart(
        id: String? = nil,
        type: WebChartType = .bar,
        labels: [String],
        options: ChartOptions = ChartOptions(),
        dataSets: ChartDataSet...
    ) -> WebChartElement {
        Chart(
            id: id,
            type: type,
            labels: labels,
            dataSets: dataSets,
            options: options
        )
    }
}
